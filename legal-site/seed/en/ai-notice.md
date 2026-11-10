---
title: AI Services Notice
description: Scope of {{site_name_en}} AI features, providers, data handling and retention, content labeling, usage limits and disclaimers.
version: 1.0.0
effective: 2026-10-27
updated: 2026-10-27
---

## 1. Scope of AI Features

AI features in the App include: training plan generation, meal-photo recognition and nutrition estimation, daily AI reports, workout interpretations, weekly body-review analysis, Club AI chat, and optional automatic daily/weekly reports and post-close follow-ups.

## 2. AI Providers

AI tasks are processed by **DeepSeek** and **MiniMax**, allocated by task and service status with mutual fallback; **image tasks are sent only to services that support images**. Legacy tasks follow the scope you originally confirmed. Providers process data only within our commissioned scope, bound by our contract and their own privacy policies.

## 3. What You Submit

1. **On-demand minimization**: each task you initiate sends only its necessary input (training records, diet records, body profile, daily health summaries, questionnaires, or your question);
2. **Photos**: meal and body-review photos are submitted only when you actively take/select them and start recognition or analysis; Club AI "upload photo" first creates an on-device pending attachment submitted only when you tap send, removable before sending; ordinary chat images are not auto-saved as meals or plans;
3. **Voice**: recordings are never uploaded; transcription happens on device where supported, and only the verified text is used for diet recognition;
4. **Avatar**: never sent in AI requests;
5. **Disabling cloud analysis**: disable anytime under Settings → Privacy Notice; pending submissions and result polling stop; tasks already sent to providers cannot be recalled instantly and may still complete.

## 4. Data Handling and Retention

- AI task request text, context, status and results are stored on the server and linked to your account. They remain while the account exists; we currently do not automatically delete these fields based on task age. Account deletion is handled through the account-deletion process.
- For completed, failed or cancelled tasks, scheduled cleanup removes inline original image bytes from task requests after the task has ended for more than 24 hours. This does not remove related text, results, status or saved meal records.
- Incremental events used to resume streaming chats are kept for up to 30 days. Removing these events does not delete the associated task text, results or saved chat messages.
- Content submitted to third-party model providers may be processed or retained under their applicable privacy notices and API terms. The App cannot directly erase copies held by a provider.
## 5. AI Content Labeling

Under the Measures for Labeling AI-Generated Synthetic Content and similar rules, AI-generated content carries explicit labels (e.g., "AI-generated") and necessary implicit labels so you can clearly distinguish AI output from human content.

## 6. Output Accuracy

AI output is generated automatically and **may be inaccurate, incomplete, outdated or unsuitable for your condition**. Do not treat it as the sole basis for medical diagnosis, nutrition prescriptions or high-intensity training; judge for yourself whether an exercise suits your body, whether the weight is safe, whether diet entries are accurate, whether health data is complete, and whether body photos are comparable. See the Health & Fitness Disclaimer.

## 7. Usage Limits

1. Do not use AI features to generate or spread unlawful, infringing, pornographic, violent, hateful, dangerous or false content;
2. Do not call the AI in bulk by automation, bypass membership quotas or disrupt stability;
3. AI calls may be subject to membership quotas and rate limits; automatic scheduling is counted separately from manual use and does not consume the member daily quota;
4. We may throttle or restrict abnormal usage.

## 8. Mainland China Compliance

When providing generative AI services to mainland China users, we comply with the Interim Measures for the Management of Generative AI Services, the Provisions on Algorithmic Recommendation, and the Measures for Labeling AI-Generated Synthetic Content, fulfilling algorithm security, content labeling, minor protection and complaint-handling duties.

## 9. Feedback and Complaints

For questions, objections or complaints about AI output or processing, contact {{contact_email}}, or use the in-App feedback entry. We will verify and respond promptly.
