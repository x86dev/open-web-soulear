MY_FLUTTER_SDK=3.47.3
MY_FLUTTER_IMG=docker.io/gmeligio/flutter-android
podman run --rm -it -v ${PWD}/flutter_app:/app:U -w /app ${MY_FLUTTER_IMG}:${MY_FLUTTER_SDK} flutter build apk --release --split-per-abi --target-platform android-arm64
