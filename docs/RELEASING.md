# Publishing on GitHub and releasing

This sets up the repository on GitHub, gives the build workflow a signing key, and publishes a release. You do steps 1–4 once; step 5 is every release.

The commands are for PowerShell on Windows, run from the project folder. They use `git`, the GitHub CLI `gh`, and `keytool`, which comes with Java.

## 1. Put the project in git

```powershell
git init -b main
git add .
git commit -m "SpoolBuddy for Android"
```

`.gitignore` already leaves out build output, `android/key.properties` and keystores (`*.jks`, `*.keystore`). Before committing, check `git status` for anything private.

## 2. Create the GitHub repository and push

```powershell
gh auth login
gh repo create spoolbuddy-android --private --source . --push
```

Use `--public` instead if you want it public. You can also create an empty repository on github.com without a README, then:

```powershell
git remote add origin https://github.com/<you>/spoolbuddy-android.git
git push -u origin main
```

The push starts the **Build** workflow under the repository's **Actions** tab. Until step 4 it builds a debug-signed APK and shows a warning saying so.

## 3. Create a signing key

Android only installs an update if it's signed with the same key as the installed app. Create one key and keep using it.

`keytool` is in Android Studio's bundled Java. If `keytool` isn't found, use the full path:

```powershell
& "C:\Program Files\Android\Android Studio\jbr\bin\keytool.exe" -genkeypair -v `
  -keystore "$HOME\spoolbuddy-upload.jks" -alias upload `
  -keyalg RSA -keysize 2048 -validity 10000
```

It asks for a keystore password and your name. Press Enter at "key password" to reuse the keystore password.

**Back up `spoolbuddy-upload.jks` and its password somewhere safe, such as a password manager.** If you lose either, you can't publish updates that install over the existing app. Keep it out of the project folder.

## 4. Give the workflow the key

The workflow reads four repository secrets. Set them with `gh`; it prompts for each value, so passwords stay out of your shell history:

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("$HOME\spoolbuddy-upload.jks")) | gh secret set ANDROID_KEYSTORE_BASE64
gh secret set ANDROID_KEYSTORE_PASSWORD
gh secret set ANDROID_KEY_PASSWORD
gh secret set ANDROID_KEY_ALIAS --body upload
```

`ANDROID_KEY_PASSWORD` is the same as the keystore password if you pressed Enter in step 3.

To set them on the website instead, go to **Settings → Secrets and variables → Actions → New repository secret**. For `ANDROID_KEYSTORE_BASE64`, copy the Base64 text with:

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("$HOME\spoolbuddy-upload.jks")) | Set-Clipboard
```

Re-run the latest workflow (**Actions → Build → Re-run jobs**). The *Show signing certificate* step should show your name, not `Android Debug`.

## 5. Release a version

Set the version in `pubspec.yaml` (`version: 0.2.0+1`; the build number after `+` is replaced by the workflow's run number), commit, then tag and push:

```powershell
git tag v0.2.0
git push origin main v0.2.0
```

The workflow builds `spoolbuddy-0.2.0.apk`, and the **release** job publishes it on the **Releases** page with notes generated from the commits.

Builds that aren't tagged are kept under **Actions** as artifacts, named like `spoolbuddy-0.1.0-dev.12`.

## Switching your phone to the release build

The app you've been running from Flutter is signed with the debug key, so Android won't install the release over it. Uninstall it first. That removes the Bambuddy pairing, so pair again afterwards; your spools are in Bambuddy and aren't affected. After that, each release installs over the last one.

## What the workflow does

`.github/workflows/build.yml`, on every push to `main`, every pull request and every `v*` tag:

1. Installs JDK 17 and Flutter 3.47.9.
2. Runs `flutter analyze` and `flutter test`.
3. Writes the keystore and `android/key.properties` from the secrets, if they're set.
4. Builds the release APK, prints its signing certificate, and deletes the key files.
5. Uploads the APK as an artifact. For tags, it also creates a GitHub release with the APK attached.

Pull requests from forks don't get secrets, so they build debug-signed.
