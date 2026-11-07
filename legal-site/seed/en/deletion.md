---
title: Account Deletion & Data Deletion Notice
description: How to delete your {{site_name_en}} account, what gets deleted, what may persist briefly, and subscription cancellation notes.
version: 1.0.0
effective: 2026-10-27
updated: 2026-10-27
---

## 1. How to Delete Your Account

In the App, open "Me" and choose "Delete Account" or email {{contact_email}}.

To protect account security we may ask you to complete one of the following: sign in to the current account; verify Apple sign-in or your phone number; enter an explicit deletion confirmation phrase; or verify identity through customer service.

## 2. What Gets Deleted

After deletion completes, we delete or anonymize:

- Account profile, credentials and membership records
- Training plans, logs and set records
- Diet records, nutrition data and synced meal photos
- Health summaries and sync state
- AI task mappings, server-side AI reports and task audits
- Weekly review summaries and account-linked server media
- Feedback and attachments
- Device bindings and push delivery records

Body photos stored locally in the App are removed with account cleanup or by you in the App. Uninstalling removes sandbox data on the device, but **cannot remove copies you saved to the system photo album or shared with others** — manage those yourself.

## 3. What May Persist Briefly

The following may not vanish instantly upon deletion:

1. Database and file backups (overwritten per rotation);
2. Security audit and anti-abuse logs (retained for legal duties);
3. Content already sent to third-party model services (subject to their retention policies);
4. Images you already downloaded or shared;
5. Transaction records kept by Apple, RevenueCat or other providers under their own policies.

We delete or anonymize identifiable data as quickly as backup rotation and internal rules allow. Once a deletion request is accepted the account is disabled immediately; cleanup continues in the background with automatic retries.

## 4. Deleting Meal Photos

Deleting a meal removes its on-device photo and record from the account; synced cloud photos are deleted too, though backups or third-party caches may persist until rotation. Failed cloud cleanup of originals enters a dedicated retry queue automatically — no repeated action needed.

## 5. Deleting Body Photos

Weekly review photos stay on your device by default. Deleting a review or photo removes the local file. Images already sent to AI services cannot be guaranteed to be recalled from third-party servers instantly: server-side inputs are cleared after task success; weekly-review inputs are cleared on final failure; other failed inputs are kept up to 7 days. Account deletion clears associated inputs, results and audits.

## 6. Revoking Health Authorization

Revoke the App's health read/write permissions in Apple Health or system settings. After revocation no new health data is read; previously saved health summaries may remain in account records — delete them or delete your account.

## 7. Subscriptions and Memberships

- **Deleting your account does not cancel your Apple subscription.** Cancel auto-renewal in your Apple ID subscription management first, then request deletion, to avoid further charges;
- Refunds for paid periods follow the Purchase, Subscription & Refund Policy via Apple;
- Deletion and subscription cancellation are two separate operations.

## 8. Revoking Apple Authorization

Where the Apple token-revocation service is configured and refresh credentials are stored, deleting the account revokes your Sign in with Apple authorization for the App. For older accounts or where revocation is not configured, revoke manually in iOS **Settings → [Your Name] → Sign-In & Security (or Password & Security) → Apps Using Apple ID**.

## 9. Status Checks and Re-registration

If you lose the deletion receipt, you can re-verify using the Apple account used at request time; the system never creates or restores an account based solely on a local flag. Deletion-credential digests and Apple-identifier digests used for status checks are kept up to 30 days after cleanup completes, then erased.

On-device export files, dual-device snapshot backups and legacy plan-text backups are removed with on-device account cleanup; copies you saved elsewhere are yours to manage and cannot be deleted by the App.

## 10. Contact

If deletion cannot be completed in the App:

- Email: {{contact_email}}


State "account deletion" or "data deletion" in your request and complete identity verification. We process within statutory timelines (generally no more than 15 working days) and inform you of the result.
