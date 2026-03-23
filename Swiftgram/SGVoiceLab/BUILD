load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "SGVoiceLab",
    module_name = "SGVoiceLab",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/OpusBinding:OpusBinding",
    ],
    visibility = [
        "//visibility:public",
    ],
)
