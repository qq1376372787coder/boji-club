<?php
// Merge into the protected server config only after Apple APNs setup.
// This is NOT a Sign in with Apple key or an App Store Connect purchase key.
return [
    'apns_enabled'=>false,
    'apns_key_id'=>'YOUR_KEYID',
    'apns_team_id'=>'GYFUN6MZ9J',
    'apns_key_path'=>'/opt/bojiclub-account/private-keys/apns.p8',
    'apns_topic'=>'com.bojiclub.app.dev',
    'apns_cache_directory'=>'/opt/bojiclub-account/private-cache',
];
