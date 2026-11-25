import Foundation
import Testing

/// scripts/check-strings.py (the release gate) and scripts/merge-translations.py, run on a small catalog of their own.
struct StringScriptsTests {
    private static let scripts = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts")

    private static let localizable = #"""
    {
      "sourceLanguage" : "en",
      "strings" : {
        "%lld tabs" : {
          "comment" : "A count of tabs.",
          "localizations" : {
            "en" : {
              "variations" : {
                "plural" : {
                  "one" : {
                    "stringUnit" : {
                      "state" : "new",
                      "value" : "%lld tab"
                    }
                  },
                  "other" : {
                    "stringUnit" : {
                      "state" : "new",
                      "value" : "%lld tabs"
                    }
                  }
                }
              }
            },
            "zh-Hans" : {
              "variations" : {
                "plural" : {
                  "other" : {
                    "stringUnit" : {
                      "state" : "translated",
                      "value" : "%lld 个标签页"
                    }
                  }
                }
              }
            }
          }
        },
        "Close %@" : {
          "comment" : "A menu item. The placeholder is a page's name.",
          "localizations" : {
            "zh-Hans" : {
              "stringUnit" : {
                "state" : "translated",
                "value" : "关闭“%@”"
              }
            }
          }
        },
        "New Tab" : {
          "comment" : "A menu item.",
          "localizations" : {
            "zh-Hans" : {
              "stringUnit" : {
                "state" : "translated",
                "value" : "新建标签页"
              }
            }
          }
        },
        "Old" : {
          "comment" : "Gone from the code.",
          "extractionState" : "stale",
          "localizations" : {
            "zh-Hans" : {
              "stringUnit" : {
                "state" : "translated",
                "value" : "旧"
              }
            }
          }
        }
      },
      "version" : "1.0"
    }
    """#

    private static let infoPlist = #"""
    {
      "sourceLanguage" : "en",
      "strings" : {
        "NSCameraUsageDescription" : {
          "comment" : "Shown by macOS when a website asks for the camera.",
          "extractionState" : "extracted_with_value",
          "localizations" : {
            "en" : {
              "stringUnit" : {
                "state" : "new",
                "value" : "Websites you visit can ask to use your camera."
              }
            },
            "zh-Hans" : {
              "stringUnit" : {
                "state" : "translated",
                "value" : "你访问的网站可以请求使用你的摄像头。"
              }
            }
          }
        }
      },
      "version" : "1.0"
    }
    """#

    private static let project = "knownRegions = (\n\tBase,\n\ten,\n\t\"zh-Hans\",\n);\n"

    /// A copy of the fixture repository, and a way to run a script against it.
    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("strings-\(UUID().uuidString)")
        var resources: URL { root.appendingPathComponent("Zigzag/Resources") }

        init() throws {
            let manager = FileManager.default
            try manager.createDirectory(at: resources, withIntermediateDirectories: true)
            try manager.createDirectory(at: root.appendingPathComponent("Zigzag.xcodeproj"), withIntermediateDirectories: true)
            try (localizable + "\n").write(to: resources.appendingPathComponent("Localizable.xcstrings"), atomically: true, encoding: .utf8)
            try infoPlist.write(to: resources.appendingPathComponent("InfoPlist.xcstrings"), atomically: true, encoding: .utf8)
            try project.write(to: root.appendingPathComponent("Zigzag.xcodeproj/project.pbxproj"), atomically: true, encoding: .utf8)
        }

        func catalog(_ name: String) throws -> String { try String(contentsOf: resources.appendingPathComponent("\(name).xcstrings"), encoding: .utf8) }

        func write(_ object: [String: Any], as name: String) throws -> String {
            let url = root.appendingPathComponent(name)
            try JSONSerialization.data(withJSONObject: object).write(to: url)
            return url.path
        }

        func run(_ script: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-I", scripts.appendingPathComponent(script).path] + arguments
            process.environment = ["ZIGZAG_REPO": root.path, "PATH": "/usr/bin:/bin"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private static func unit(_ value: String, _ state: String = "translated") -> [String: Any] {
        ["stringUnit": ["state": state, "value": value]]
    }

    private static func plural(_ forms: [String: String]) -> [String: Any] {
        ["variations": ["plural": forms.mapValues { unit($0) }]]
    }

    /// A complete Korean file for the fixture.
    private static func korean() -> [String: Any] {
        ["language": "ko",
         "Localizable": ["%lld tabs": plural(["other": "탭 %lld개"]), "Close %@": unit("%@ 닫기"), "New Tab": unit("새로운 탭")],
         "InfoPlist": ["NSCameraUsageDescription": unit("방문하는 웹사이트가 카메라 사용을 요청할 수 있습니다.")]]
    }

    @Test func theGatePassesWhenEveryShippedLanguageIsDone() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let result = try fixture.run("check-strings.py", [])
        #expect(result.status == 0, "\(result.output)")
        #expect(result.output.contains("zh-Hans: every string is translated"))
    }

    @Test func theGateNamesWhatALanguageLacks() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        // One string back to needs_review, one taking the wrong argument.
        let url = fixture.resources.appendingPathComponent("Localizable.xcstrings")
        var catalog = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var strings = catalog["strings"] as? [String: Any] ?? [:]
        strings["New Tab"] = ["localizations": ["zh-Hans": Self.unit("新建标签页", "needs_review")]]
        strings["Close %@"] = ["localizations": ["zh-Hans": Self.unit("关闭 %lld")]]
        catalog["strings"] = strings
        try JSONSerialization.data(withJSONObject: catalog).write(to: url)
        let result = try fixture.run("check-strings.py", [])
        #expect(result.status == 1)
        #expect(result.output.contains("zh-Hans: 2 strings"))
        #expect(result.output.contains("'New Tab': string is needs_review"))
        #expect(result.output.contains("'Close %@': string reads 1:%lld, the English 1:%@"))
        // A language with no strings yet lacks all of them.
        let japanese = try fixture.run("check-strings.py", ["ja"])
        #expect(japanese.status == 1 && japanese.output.contains("ja: 4 strings"), "\(japanese.output)")
    }

    @Test func aCompleteFileMergesAddingOnlyItsLines() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let before = try ["Localizable", "InfoPlist"].map(fixture.catalog)
        let file = try fixture.write(Self.korean(), as: "ko.json")
        let dry = try fixture.run("merge-translations.py", ["--check", file])
        #expect(dry.status == 0, "\(dry.output)")
        #expect(try ["Localizable", "InfoPlist"].map(fixture.catalog) == before, "--check writes nothing")

        let merged = try fixture.run("merge-translations.py", [file])
        #expect(merged.status == 0, "\(merged.output)")
        let after = try ["Localizable", "InfoPlist"].map(fixture.catalog)
        for (old, new) in zip(before, after) {
            // Every old line is still there, in order: the merge only added lines.
            var lines = new.components(separatedBy: "\n")[...]
            for line in old.components(separatedBy: "\n") {
                guard let at = lines.firstIndex(of: line) else { Issue.record("lost \(line)"); break }
                lines = lines[(at + 1)...]
            }
            #expect(new.count > old.count)
        }
        // Korean sits between English and Chinese, in Xcode's layout.
        #expect(after[0].contains("""
                    "ko" : {
                      "stringUnit" : {
                        "state" : "translated",
                        "value" : "새로운 탭"
                      }
                    },
                    "zh-Hans" : {
            """))
        #expect(after[1].hasSuffix("}"), "InfoPlist.xcstrings still ends without a newline")
        // Korean now ships, and the gate finds it complete.
        let gate = try fixture.run("check-strings.py", ["ko", "zh-Hans"])
        #expect(gate.status == 0, "\(gate.output)")
        // Merging the same file again changes nothing.
        _ = try fixture.run("merge-translations.py", [file])
        #expect(try ["Localizable", "InfoPlist"].map(fixture.catalog) == after)
    }

    @Test func aWrongFileIsRefusedWithAReport() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let before = try fixture.catalog("Localizable")
        var korean = Self.korean()
        var strings = korean["Localizable"] as? [String: Any] ?? [:]
        strings["Close %@"] = Self.unit("%lld 닫기")
        strings["New Tab"] = Self.unit("새로운 탭", "needs_review")
        strings["Not in the catalog"] = Self.unit("없음")
        strings["%lld tabs"] = Self.unit("탭 %lld개")
        korean["Localizable"] = strings
        korean["InfoPlist"] = [String: Any]()
        let file = try fixture.write(korean, as: "ko.json")
        let result = try fixture.run("merge-translations.py", [file])
        #expect(result.status == 1)
        for line in ["unknown key 'Not in the catalog'", "'Close %@': string reads 1:%lld, the English 1:%@",
                     "'New Tab': string is needs_review", "'%lld tabs': plural has no other form",
                     "InfoPlist: 1 keys missing", "Nothing was merged."] {
            #expect(result.output.contains(line), "\(line) in \(result.output)")
        }
        #expect(try fixture.catalog("Localizable") == before)
        // A file named for another language is refused too.
        let misnamed = try fixture.write(Self.korean(), as: "de.json")
        #expect(try fixture.run("merge-translations.py", ["--check", misnamed]).output.contains("doesn't match the file name"))
        // A partial file merges with --allow-missing.
        var partial = Self.korean()
        partial["InfoPlist"] = [String: Any]()
        let partialFile = try fixture.write(partial, as: "ko.json")
        #expect(try fixture.run("merge-translations.py", ["--check", partialFile]).status == 1)
        #expect(try fixture.run("merge-translations.py", ["--check", "--allow-missing", partialFile]).status == 0)
    }
}
