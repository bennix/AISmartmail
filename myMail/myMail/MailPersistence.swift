//
//  MailPersistence.swift
//  myMail
//

import CoreData
import Foundation

enum MailCoreDataModelFactory {
    static func makeModel() -> NSManagedObjectModel {
        let account = entity("Account", attributes: [
            attribute("id", .UUIDAttributeType),
            attribute("displayName", .stringAttributeType),
            attribute("emailAddress", .stringAttributeType),
            attribute("provider", .stringAttributeType),
            attribute("authType", .stringAttributeType),
            attribute("imapHost", .stringAttributeType),
            attribute("imapPort", .integer64AttributeType),
            attribute("imapTLS", .stringAttributeType),
            attribute("smtpHost", .stringAttributeType),
            attribute("smtpPort", .integer64AttributeType),
            attribute("smtpTLS", .stringAttributeType),
            attribute("pop3Host", .stringAttributeType, optional: true),
            attribute("pop3Port", .integer64AttributeType, optional: true),
            attribute("pop3TLS", .stringAttributeType, optional: true),
            attribute("useProtocol", .stringAttributeType),
            attribute("oauthRefreshTokenRef", .stringAttributeType, optional: true),
            attribute("createdAt", .dateAttributeType),
            attribute("needsReauth", .booleanAttributeType)
        ])

        let mailbox = entity("Mailbox", attributes: [
            attribute("id", .UUIDAttributeType),
            attribute("accountId", .UUIDAttributeType),
            attribute("name", .stringAttributeType),
            attribute("role", .stringAttributeType),
            attribute("uidValidity", .integer64AttributeType),
            attribute("unreadCount", .integer64AttributeType)
        ])

        let message = entity("Message", attributes: [
            attribute("id", .UUIDAttributeType),
            attribute("accountId", .UUIDAttributeType),
            attribute("mailboxId", .UUIDAttributeType),
            attribute("uid", .integer64AttributeType),
            attribute("messageId", .stringAttributeType),
            attribute("subject", .stringAttributeType),
            attribute("fromAddress", .stringAttributeType),
            attribute("fromName", .stringAttributeType),
            attribute("toRecipients", .stringAttributeType),
            attribute("ccRecipients", .stringAttributeType),
            attribute("bccRecipients", .stringAttributeType),
            attribute("date", .dateAttributeType),
            attribute("snippet", .stringAttributeType),
            attribute("bodyPlain", .stringAttributeType, optional: true),
            attribute("bodyHTML", .stringAttributeType, optional: true),
            attribute("flagsRawValue", .integer64AttributeType),
            attribute("hasAttachments", .booleanAttributeType),
            attribute("isBodyDownloaded", .booleanAttributeType),
            attribute("embeddingState", .stringAttributeType)
        ])

        let attachment = entity("Attachment", attributes: [
            attribute("id", .UUIDAttributeType),
            attribute("messageId", .UUIDAttributeType),
            attribute("filename", .stringAttributeType),
            attribute("mimeType", .stringAttributeType),
            attribute("sizeBytes", .integer64AttributeType),
            attribute("localPath", .stringAttributeType, optional: true),
            attribute("contentId", .stringAttributeType, optional: true)
        ])

        addRelationship(name: "mailboxes", from: account, to: mailbox, min: 0, max: 0, deleteRule: .cascadeDeleteRule, toMany: true)
        addRelationship(name: "account", from: mailbox, to: account, min: 0, max: 1, deleteRule: .nullifyDeleteRule, toMany: false)
        addRelationship(name: "messages", from: mailbox, to: message, min: 0, max: 0, deleteRule: .cascadeDeleteRule, toMany: true)
        addRelationship(name: "mailbox", from: message, to: mailbox, min: 0, max: 1, deleteRule: .nullifyDeleteRule, toMany: false)
        addRelationship(name: "attachments", from: message, to: attachment, min: 0, max: 0, deleteRule: .cascadeDeleteRule, toMany: true)
        addRelationship(name: "message", from: attachment, to: message, min: 0, max: 1, deleteRule: .nullifyDeleteRule, toMany: false)

        message.uniquenessConstraints = [["messageId"]]
        message.indexes = [
            NSFetchIndexDescription(
                name: "message_account_mailbox_uid",
                elements: [
                    NSFetchIndexElementDescription(property: message.propertiesByName["accountId"]!, collationType: .binary),
                    NSFetchIndexElementDescription(property: message.propertiesByName["mailboxId"]!, collationType: .binary),
                    NSFetchIndexElementDescription(property: message.propertiesByName["uid"]!, collationType: .binary)
                ]
            )
        ]

        let model = NSManagedObjectModel()
        model.entities = [account, mailbox, message, attachment]
        return model
    }

    private static func entity(_ name: String, attributes: [NSAttributeDescription]) -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = name
        entity.managedObjectClassName = "NSManagedObject"
        entity.properties = attributes
        return entity
    }

    private static func attribute(_ name: String, _ type: NSAttributeType, optional: Bool = false) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = type
        attribute.isOptional = optional
        return attribute
    }

    private static func addRelationship(
        name: String,
        from source: NSEntityDescription,
        to destination: NSEntityDescription,
        min: Int,
        max: Int,
        deleteRule: NSDeleteRule,
        toMany: Bool
    ) {
        let relationship = NSRelationshipDescription()
        relationship.name = name
        relationship.destinationEntity = destination
        relationship.minCount = min
        relationship.maxCount = max
        relationship.deleteRule = deleteRule
        relationship.isOptional = min == 0
        source.properties.append(relationship)
    }
}

final class CoreDataStack {
    let container: NSPersistentContainer

    init(inMemory: Bool = false) {
        container = NSPersistentContainer(name: "myMail", managedObjectModel: MailCoreDataModelFactory.makeModel())
        if inMemory {
            let description = NSPersistentStoreDescription()
            description.type = NSInMemoryStoreType
            container.persistentStoreDescriptions = [description]
        }
        container.loadPersistentStores { _, error in
            if let error {
                assertionFailure("Core Data 初始化失败: \(error)")
            }
        }
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        container.viewContext.automaticallyMergesChangesFromParent = true
    }
}

struct MailStoreSnapshot: Equatable {
    var accounts: [MailAccount]
    var mailboxes: [Mailbox]
    var messages: [MailMessage]
    var attachments: [MailAttachment]
}

@MainActor
protocol MailStore {
    func loadSnapshot() throws -> MailStoreSnapshot
    func saveSnapshot(_ snapshot: MailStoreSnapshot) throws
}

@MainActor
final class CoreDataMailStore: MailStore {
    private let context: NSManagedObjectContext

    init(stack: CoreDataStack) {
        self.context = stack.container.viewContext
    }

    func loadSnapshot() throws -> MailStoreSnapshot {
        MailStoreSnapshot(
            accounts: try fetch(entityName: "Account").compactMap(makeAccount).sorted { $0.createdAt < $1.createdAt },
            mailboxes: try fetch(entityName: "Mailbox").compactMap(makeMailbox).sorted { $0.name < $1.name },
            messages: try fetch(entityName: "Message").compactMap(makeMessage).sorted { $0.uid < $1.uid },
            attachments: try fetch(entityName: "Attachment").compactMap(makeAttachment).sorted { $0.filename < $1.filename }
        )
    }

    func saveSnapshot(_ snapshot: MailStoreSnapshot) throws {
        try deleteAll(entityNames: ["Attachment", "Message", "Mailbox", "Account"])
        snapshot.accounts.forEach(insertAccount)
        snapshot.mailboxes.forEach(insertMailbox)
        snapshot.messages.forEach(insertMessage)
        snapshot.attachments.forEach(insertAttachment)
        if context.hasChanges {
            try context.save()
        }
    }

    private func fetch(entityName: String) throws -> [NSManagedObject] {
        let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
        return try context.fetch(request)
    }

    private func deleteAll(entityNames: [String]) throws {
        for entityName in entityNames {
            for object in try fetch(entityName: entityName) {
                context.delete(object)
            }
        }
    }

    private func insertAccount(_ account: MailAccount) {
        let object = NSEntityDescription.insertNewObject(forEntityName: "Account", into: context)
        object.setValue(account.id, forKey: "id")
        object.setValue(account.displayName, forKey: "displayName")
        object.setValue(account.emailAddress, forKey: "emailAddress")
        object.setValue(account.provider.rawValue, forKey: "provider")
        object.setValue(account.authType.rawValue, forKey: "authType")
        object.setValue(account.imap.host, forKey: "imapHost")
        object.setValue(Int64(account.imap.port), forKey: "imapPort")
        object.setValue(account.imap.tlsMode, forKey: "imapTLS")
        object.setValue(account.smtp.host, forKey: "smtpHost")
        object.setValue(Int64(account.smtp.port), forKey: "smtpPort")
        object.setValue(account.smtp.tlsMode, forKey: "smtpTLS")
        object.setValue(account.pop3?.host, forKey: "pop3Host")
        object.setValue(account.pop3.map { Int64($0.port) }, forKey: "pop3Port")
        object.setValue(account.pop3?.tlsMode, forKey: "pop3TLS")
        object.setValue(account.useProtocol.rawValue, forKey: "useProtocol")
        object.setValue(account.oauthRefreshTokenRef, forKey: "oauthRefreshTokenRef")
        object.setValue(account.createdAt, forKey: "createdAt")
        object.setValue(account.needsReauth, forKey: "needsReauth")
    }

    private func insertMailbox(_ mailbox: Mailbox) {
        let object = NSEntityDescription.insertNewObject(forEntityName: "Mailbox", into: context)
        object.setValue(mailbox.id, forKey: "id")
        object.setValue(mailbox.accountId, forKey: "accountId")
        object.setValue(mailbox.name, forKey: "name")
        object.setValue(mailbox.role.rawValue, forKey: "role")
        object.setValue(mailbox.uidValidity, forKey: "uidValidity")
        object.setValue(Int64(mailbox.unreadCount), forKey: "unreadCount")
    }

    private func insertMessage(_ message: MailMessage) {
        let object = NSEntityDescription.insertNewObject(forEntityName: "Message", into: context)
        object.setValue(message.id, forKey: "id")
        object.setValue(message.accountId, forKey: "accountId")
        object.setValue(message.mailboxId, forKey: "mailboxId")
        object.setValue(message.uid, forKey: "uid")
        object.setValue(message.messageId, forKey: "messageId")
        object.setValue(message.subject, forKey: "subject")
        object.setValue(message.fromAddress, forKey: "fromAddress")
        object.setValue(message.fromName, forKey: "fromName")
        object.setValue(message.toRecipientsJSON, forKey: "toRecipients")
        object.setValue(message.ccRecipientsJSON, forKey: "ccRecipients")
        object.setValue(message.bccRecipientsJSON, forKey: "bccRecipients")
        object.setValue(message.date, forKey: "date")
        object.setValue(message.snippet, forKey: "snippet")
        object.setValue(message.bodyPlain, forKey: "bodyPlain")
        object.setValue(message.bodyHTML, forKey: "bodyHTML")
        object.setValue(Int64(message.flags.rawValue), forKey: "flagsRawValue")
        object.setValue(message.hasAttachments, forKey: "hasAttachments")
        object.setValue(message.isBodyDownloaded, forKey: "isBodyDownloaded")
        object.setValue(message.embeddingState.rawValue, forKey: "embeddingState")
    }

    private func insertAttachment(_ attachment: MailAttachment) {
        let object = NSEntityDescription.insertNewObject(forEntityName: "Attachment", into: context)
        object.setValue(attachment.id, forKey: "id")
        object.setValue(attachment.messageId, forKey: "messageId")
        object.setValue(attachment.filename, forKey: "filename")
        object.setValue(attachment.mimeType, forKey: "mimeType")
        object.setValue(attachment.sizeBytes, forKey: "sizeBytes")
        object.setValue(attachment.localPath, forKey: "localPath")
        object.setValue(attachment.contentId, forKey: "contentId")
    }

    private func makeAccount(_ object: NSManagedObject) -> MailAccount? {
        guard
            let id = object.value(forKey: "id") as? UUID,
            let displayName = object.value(forKey: "displayName") as? String,
            let emailAddress = object.value(forKey: "emailAddress") as? String,
            let providerRaw = object.value(forKey: "provider") as? String,
            let provider = MailProvider(rawValue: providerRaw),
            let authRaw = object.value(forKey: "authType") as? String,
            let authType = MailAuthType(rawValue: authRaw),
            let imapHost = object.value(forKey: "imapHost") as? String,
            let imapPort = object.value(forKey: "imapPort") as? Int64,
            let imapTLS = object.value(forKey: "imapTLS") as? String,
            let smtpHost = object.value(forKey: "smtpHost") as? String,
            let smtpPort = object.value(forKey: "smtpPort") as? Int64,
            let smtpTLS = object.value(forKey: "smtpTLS") as? String,
            let protocolRaw = object.value(forKey: "useProtocol") as? String,
            let useProtocol = MailProtocolChoice(rawValue: protocolRaw),
            let createdAt = object.value(forKey: "createdAt") as? Date
        else {
            return nil
        }

        let pop3: ServerEndpoint?
        if let pop3Host = object.value(forKey: "pop3Host") as? String,
           let pop3Port = object.value(forKey: "pop3Port") as? Int64,
           let pop3TLS = object.value(forKey: "pop3TLS") as? String {
            pop3 = ServerEndpoint(host: pop3Host, port: Int(pop3Port), tlsMode: pop3TLS)
        } else {
            pop3 = nil
        }

        return MailAccount(
            id: id,
            displayName: displayName,
            emailAddress: emailAddress,
            provider: provider,
            authType: authType,
            imap: ServerEndpoint(host: imapHost, port: Int(imapPort), tlsMode: imapTLS),
            smtp: ServerEndpoint(host: smtpHost, port: Int(smtpPort), tlsMode: smtpTLS),
            pop3: pop3,
            useProtocol: useProtocol,
            oauthRefreshTokenRef: object.value(forKey: "oauthRefreshTokenRef") as? String,
            createdAt: createdAt,
            needsReauth: (object.value(forKey: "needsReauth") as? Bool) ?? false
        )
    }

    private func makeMailbox(_ object: NSManagedObject) -> Mailbox? {
        guard
            let id = object.value(forKey: "id") as? UUID,
            let accountId = object.value(forKey: "accountId") as? UUID,
            let name = object.value(forKey: "name") as? String,
            let roleRaw = object.value(forKey: "role") as? String,
            let role = MailboxRole(rawValue: roleRaw),
            let uidValidity = object.value(forKey: "uidValidity") as? Int64,
            let unreadCount = object.value(forKey: "unreadCount") as? Int64
        else {
            return nil
        }

        return Mailbox(id: id, accountId: accountId, name: name, role: role, uidValidity: uidValidity, unreadCount: Int(unreadCount))
    }

    private func makeMessage(_ object: NSManagedObject) -> MailMessage? {
        guard
            let id = object.value(forKey: "id") as? UUID,
            let accountId = object.value(forKey: "accountId") as? UUID,
            let mailboxId = object.value(forKey: "mailboxId") as? UUID,
            let uid = object.value(forKey: "uid") as? Int64,
            let messageId = object.value(forKey: "messageId") as? String,
            let subject = object.value(forKey: "subject") as? String,
            let fromAddress = object.value(forKey: "fromAddress") as? String,
            let fromName = object.value(forKey: "fromName") as? String,
            let toRecipients = object.value(forKey: "toRecipients") as? String,
            let ccRecipients = object.value(forKey: "ccRecipients") as? String,
            let bccRecipients = object.value(forKey: "bccRecipients") as? String,
            let date = object.value(forKey: "date") as? Date,
            let snippet = object.value(forKey: "snippet") as? String,
            let flagsRawValue = object.value(forKey: "flagsRawValue") as? Int64,
            let embeddingRaw = object.value(forKey: "embeddingState") as? String,
            let embeddingState = MessageEmbeddingState(rawValue: embeddingRaw)
        else {
            return nil
        }

        return MailMessage(
            id: id,
            accountId: accountId,
            mailboxId: mailboxId,
            uid: uid,
            messageId: messageId,
            subject: subject,
            fromAddress: fromAddress,
            fromName: fromName,
            toRecipientsJSON: toRecipients,
            ccRecipientsJSON: ccRecipients,
            bccRecipientsJSON: bccRecipients,
            date: date,
            snippet: snippet,
            bodyPlain: object.value(forKey: "bodyPlain") as? String,
            bodyHTML: object.value(forKey: "bodyHTML") as? String,
            flags: MessageFlags(rawValue: Int(flagsRawValue)),
            hasAttachments: (object.value(forKey: "hasAttachments") as? Bool) ?? false,
            isBodyDownloaded: (object.value(forKey: "isBodyDownloaded") as? Bool) ?? false,
            embeddingState: embeddingState
        )
    }

    private func makeAttachment(_ object: NSManagedObject) -> MailAttachment? {
        guard
            let id = object.value(forKey: "id") as? UUID,
            let messageId = object.value(forKey: "messageId") as? UUID,
            let filename = object.value(forKey: "filename") as? String,
            let mimeType = object.value(forKey: "mimeType") as? String,
            let sizeBytes = object.value(forKey: "sizeBytes") as? Int64
        else {
            return nil
        }

        return MailAttachment(
            id: id,
            messageId: messageId,
            filename: filename,
            mimeType: mimeType,
            sizeBytes: sizeBytes,
            localPath: object.value(forKey: "localPath") as? String,
            contentId: object.value(forKey: "contentId") as? String
        )
    }
}
