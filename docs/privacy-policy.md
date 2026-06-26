# myMail Privacy Policy Draft

Last updated: 2026-06-26

This draft is prepared for the public privacy policy URL required by App Store Connect. Publish it on the same site used for the support URL before submission.

## Overview

myMail is a macOS mail client for connecting to mail accounts selected and configured by the user. It does not sell user data, does not show advertising, and does not track users across apps or websites.

## Data Processed For Mail Functionality

myMail processes the following data to provide mail functionality:

- Email address and account configuration.
- Mail headers, message bodies, folders, read state, star state, and local mail cache.
- Attachments opened or saved by the user.
- Server settings for IMAP, SMTP, and POP3.

Mail content is sent to the mail servers configured by the user as part of normal email receiving and sending.

## Credentials And Secrets

Passwords, app-specific passwords, OAuth tokens, and API keys are stored in macOS Keychain. myMail does not store those secrets in UserDefaults or in the local mail cache.

## Optional AI Features

AI features are optional. Normal receiving, reading, searching, and sending mail do not require an AI model or API key.

If the user enables local vectorization, myMail builds an index on the Mac using local system capabilities where available.

If the user enables remote vectorization or remote AI answers, mail text and readable attachment text may be sent to the AI provider configured by the user. myMail shows a notice before enabling remote vectorization. The user can choose not to initialize the vector index and still use core mail features.

## Attachments

Attachments are stored and opened only for mail functionality. When the user chooses to save an attachment, myMail writes the file to the user-selected location.

## Tracking And Advertising

myMail does not track users across apps or websites and does not include third-party advertising SDKs.

## Data Deletion

Deleting an account in myMail removes local account configuration, local cached mail for that account, and associated Keychain credentials managed by the app.

## Contact

For privacy questions, use the support contact published on myMail's App Store product page.
