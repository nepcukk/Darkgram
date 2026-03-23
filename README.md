# Darkgram

Privacy-first Telegram fork for iOS

Darkgram — это продвинутый форк Telegram для iPhone с упором на приватность, контроль, power-user функции и встроенные AI-возможности.

Это не тема, не “обёртка”, не фейковый AyuGram для iOS и не схема с доступом к чужому iCloud.  
Darkgram — это реальный iOS-клиент на базе Telegram-iOS / Swiftgram с открытым исходным кодом, собственной логикой, собственными настройками и дополнительными функциями поверх обычного Telegram.

## Основные возможности

- Ghost Mode / расширенные privacy-функции
- Anti-delete / deleted history / archive
- Контроль read / online / story activity
- Видео → кружок / аудио / voice message
- Voice changer для голосовых сообщений
- Voice changer для личных звонков
- Voice changer для групповых звонков
- Встроенный AI прямо внутри клиента
- Фильтры, utility-функции и дополнительные сценарии использования
- Собственный sync-слой
- Open source и прозрачная разработка

## Важно

Darkgram — это **неофициальный Telegram-клиент**.  
Проект не связан с Telegram FZ-LLC, Apple или AyuGram.

Darkgram:
- **не требует входа в чужой iCloud**
- **не запрашивает Apple ID и пароль**
- **не использует “магические” схемы установки**
- **не является скамом или фейковой сборкой без исходников**

Если вы используете Darkgram, вы всегда можете проверить исходный код, структуру проекта и направление разработки самостоятельно.

## Open Source

Мы считаем, что модифицированный клиент должен быть прозрачным.  
Поэтому Darkgram развивается как открытый проект: код, архитектура и изменения должны быть понятны сообществу и разработчикам.

Если вы делаете форк, модификацию или используете части проекта, пожалуйста, соблюдайте лицензии оригинальных компонентов и публикуйте свои изменения там, где это требуется лицензией.

## Ссылки

- Репозиторий: [GitHub]
- Telegram channel: @darkgraam (https://t.me/darkgraam)
- Telegram chat: @darkgraam_chat (https://t.me/darkgraam_chat)

---

# Сборка Darkgram

Darkgram собирается примерно так же, как и официальный Telegram iOS / Swiftgram.  
Ниже — базовая инструкция по локальной сборке.


1. [**Obtain your own api_id**](https://core.telegram.org/api/obtaining_api_id) for your application.
2. Please **do not** use the name Telegram for your app — or make sure your users understand that it is unofficial.
3. Kindly **do not** use our standard logo (white paper plane in a blue circle) as your app's logo.
3. Please study our [**security guidelines**](https://core.telegram.org/mtproto/security_guidelines) and take good care of your users' data and privacy.
4. Please remember to publish **your** code too in order to comply with the licences.

# Quick Compilation Guide

## Get the Code

```
git clone --recursive -j8 https://github.com/Swiftgram/Telegram-iOS.git
```

## Setup Xcode

Install Xcode (directly from https://developer.apple.com/download/applications or using the App Store).

## Adjust Configuration

1. Generate a random identifier:
```
openssl rand -hex 8
```
2. Create a new Xcode project. Use `Swiftgram` as the Product Name. Use `org.{identifier from step 1}` as the Organization Identifier.
3. Open `Keychain Access` and navigate to `Certificates`. Locate `Apple Development: your@email.address (XXXXXXXXXX)` and double tap the certificate. Under `Details`, locate `Organizational Unit`. This is the Team ID.
4. Edit `build-system/template_minimal_development_configuration.json`. Use data from the previous steps.

## Generate an Xcode project

```
python3 build-system/Make/Make.py \
    --cacheDir="$HOME/telegram-bazel-cache" \
    generateProject \
    --configurationPath=build-system/template_minimal_development_configuration.json \
    --xcodeManagedCodesigning
```

# Advanced Compilation Guide

## Xcode

1. Copy and edit `build-system/appstore-configuration.json`.
2. Copy `build-system/fake-codesigning`. Create and download provisioning profiles, using the `profiles` folder as a reference for the entitlements.
3. Generate an Xcode project:
```
python3 build-system/Make/Make.py \
    --cacheDir="$HOME/telegram-bazel-cache" \
    generateProject \
    --configurationPath=configuration_from_step_1.json \
    --codesigningInformationPath=directory_from_step_2
```

## IPA

1. Repeat the steps from the previous section. Use distribution provisioning profiles.
2. Run:
```
python3 build-system/Make/Make.py \
    --cacheDir="$HOME/telegram-bazel-cache" \
    build \
    --configurationPath=...see previous section... \
    --codesigningInformationPath=...see previous section... \
    --buildNumber=100001 \
    --configuration=release_arm64
```

# FAQ

## Xcode is stuck at "build-request.json not updated yet"

Occasionally, you might observe the following message in your build log:
```
"/Users/xxx/Library/Developer/Xcode/DerivedData/Telegram-xxx/Build/Intermediates.noindex/XCBuildData/xxx.xcbuilddata/build-request.json" not updated yet, waiting...
```

Should this occur, simply cancel the ongoing build and initiate a new one.

## Telegram_xcodeproj: no such package 

Following a system restart, the auto-generated Xcode project might encounter a build failure accompanied by this error:
```
ERROR: Skipping '@rules_xcodeproj_generated//generator/Telegram/Telegram_xcodeproj:Telegram_xcodeproj': no such package '@rules_xcodeproj_generated//generator/Telegram/Telegram_xcodeproj': BUILD file not found in directory 'generator/Telegram/Telegram_xcodeproj' of external repository @rules_xcodeproj_generated. Add a BUILD file to a directory to mark it as a package.
```

If you encounter this issue, re-run the project generation steps in the README.


# Tips

## Codesigning is not required for simulator-only builds

Add `--disableProvisioningProfiles`:
```
python3 build-system/Make/Make.py \
    --cacheDir="$HOME/telegram-bazel-cache" \
    generateProject \
    --configurationPath=path-to-configuration.json \
    --codesigningInformationPath=path-to-provisioning-data \
    --disableProvisioningProfiles
```

## Versions

Each release is built using a specific Xcode version (see `versions.json`). The helper script checks the versions of the installed software and reports an error if they don't match the ones specified in `versions.json`. It is possible to bypass these checks:

```
python3 build-system/Make/Make.py --overrideXcodeVersion build ... # Don't check the version of Xcode
```
