/// Public web pages about account and data deletion, in one place so the
/// app UI, the Play Console "Data safety" form and the store listing all
/// point to the same addresses.
///
/// Google Play requires a page, reachable without the app, where users can
/// request deletion of their account and data. Null until that page is
/// published; the app then simply doesn't show the link.
library;

/// "UtaNote 계정 및 데이터 삭제 요청" web page (outside the app).
// ignore: unnecessary_nullable_for_final_variable_declarations
const String? kAccountDeletionRequestUrl =
    'https://lee-eunmin.github.io/utanote-account-deletion/';

/// Privacy policy page.
// ignore: unnecessary_nullable_for_final_variable_declarations
const String? kPrivacyPolicyUrl =
    'https://docs.google.com/document/d/e/2PACX-1vRNG4p1IuKYHKLgS7ahPAWu5_MH4vmY8JTvVZjpE8Yi-pFvP6donk4ll6QQRQ0ikq8w5Wgcy428km3F/pub';
