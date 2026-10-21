# Firestore security-rule tests

Tests `../firestore.rules` against the **local Firestore emulator** only.
The project id is `demo-utanote-rules` (`demo-` ids can never reach a real
Firebase project), so nothing here touches `utanote-50d07`.

Needs Node 18+, Java 11+ and the Firebase CLI.

```sh
npm install --prefix firestore_rules_test
firebase emulators:exec --only firestore --project demo-utanote-rules "npm --prefix firestore_rules_test test"
```
