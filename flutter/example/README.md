# hive_push example

A one-screen app: it registers the install for push, signs in a demo user and shows the live inbox.

1. Generate the platform folders and connect Firebase:

   ```sh
   flutter create --platforms=ios,android .
   dart pub global activate flutterfire_cli && flutterfire configure
   ```

2. In Xcode, add the **Push Notifications** capability to the Runner target (and **Background Modes >
   Remote notifications** if you send background pushes).
3. Replace `pk_...` in `lib/main.dart` with your app's public key, and `fetchUserToken` with a call to
   your own server, which makes user tokens with the app's secret key.
4. `flutter run`
