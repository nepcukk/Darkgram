load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "SGDarkEncryption",
    module_name = "SGDarkEncryption",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/MtProtoKit:MtProtoKit",
        "//submodules/CryptoUtils:CryptoUtils",
    ],
    visibility = [
        "//visibility:public",
    ],
)
