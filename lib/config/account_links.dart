/// Public web pages about account and data deletion, in one place so the
/// app UI, the Play Console "Data safety" form and the store listing all
/// point to the same addresses.
///
/// Google Play requires a page, reachable without the app, where users can
/// request deletion of their account and data. Null until that page is
/// published; the app then simply doesn't show the link.
library;

/// "UtaNote 계정 및 데이터 삭제 요청" web page (outside the app).
const String? kAccountDeletionRequestUrl = null;

/// Privacy policy page.
const String? kPrivacyPolicyUrl = null;
