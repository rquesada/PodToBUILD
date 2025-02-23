//
//  PodStore.swift
//  PodToBUILD
//
//  Created by Jerry Marino on 5/9/17.
//  Copyright © 2017 Pinterest Inc. All rights reserved.
//

import Foundation
import PodToBUILD
import ObjcSupport

/// The directory where we store things.
/// Only public for testing!
let PodStoreCacheDir = "\(NSHomeDirectory())/.bazel_pod_store/"

enum RepoToolsActionValue: String {
    case fetch
    case initialize = "init"
    case generateWorkspace = "generate_workspace"
}

/// Fetch options are command line options for a given fetch
public struct FetchOptions {
    public let podName: String
    public let url: String
    public let trace: Bool
    public let subDir: String?
}


public struct WorkspaceOptions {
    public let vendorize: Bool = true
    public let trace: Bool
}

/// Parse in Command Line arguments
/// Example: PodName --user_option Opt1

enum CLIArgumentType {
    case bool
    case stringList
    case string
}

public enum SerializedRepoToolsAction {
    case fetch(FetchOptions)
    case initialize(BasicBuildOptions)
    case generateWorkspace(WorkspaceOptions)

    public static func parse(args: [String]) -> SerializedRepoToolsAction {
        guard args.count >= 1 else {
            print("Usage: PodName <init|fetch|generate_workspace> ")
            exit(0)
        }

        // Program, Action
        // or
        // Program, PodName, Action
        let actionStr = args.count == 2 ? args[1] : args[2]
        guard let action = RepoToolsActionValue(rawValue: actionStr) else {
            print("Usage: PodName <init|fetch|generate_workspace> ")
            fatalError()
        }
        switch action {
        case .fetch:
            let fetchOpts = SerializedRepoToolsAction.tryParseFetch(args: args)
            return .fetch(fetchOpts)
        case .initialize:
            let initOpts = SerializedRepoToolsAction.tryParseInit(args: args)
            return .initialize(initOpts)
        case .generateWorkspace:
            let trace = UserDefaults.standard.bool(forKey: "-trace")
            return .generateWorkspace(WorkspaceOptions(trace: trace))
        }
    }

    static func tryParseFetch(args: [String]) -> FetchOptions {
        guard args.count >= 2,
            /// This is a bit insane ( the argument is --url )
            let url = UserDefaults.standard.string(forKey: "-url")
        else {
            print("Usage: PodSpecName <action> --url <URL> --trace <trace>")
            exit(0)
        }

        let name = args[1]
        let trace = UserDefaults.standard.bool(forKey: "-trace")
        let subDir = UserDefaults.standard.string(forKey: "-sub_dir")
        let fetchOpts = FetchOptions(podName: name, url: url, trace: trace,
                                     subDir: subDir)
        return fetchOpts
    }

    static func tryParseInit(args: [String]) -> BasicBuildOptions {
        // First arg is the path, we don't care about it
        // The right most option will be the winner.
        var options: [String: CLIArgumentType] = [
            "--path": .string,
            "--user_option": .stringList,
            "--global_copt": .string,
            "--trace": .bool,
            "--enable_modules": .bool,
            "--generate_module_map": .bool,
            "--generate_header_map": .bool,
            "--vendorize": .bool,
            "--header_visibility": .string,
            "--child_path": .stringList,
        ]

        var idx = 0
        func error() {
            let optsInfo = options.keys.map { $0 }.joined(separator: " ")
            print("Usage: PodspecName " + optsInfo)
            exit(0)
        }

        func nextArg() -> String {
            if idx + 1 < args.count {
                idx += 1
            } else {
                error()
            }
            return args[idx]
        }

        // There is no flag for the podName of the Pod
        let podName = nextArg()
        var parsed = [String: [Any]]()
        _ = nextArg()
        while true {
            idx += 1
            if (idx < args.count) == false {
                break
            }
            let arg = args[idx]
            if let argTy = options[arg] {
                var collected: [Any] = parsed[arg] ?? [Any]()
                let argValue = nextArg()
                switch argTy {
                case .bool:
                    let value = argValue == "true"
                    collected.append(value)
                case .stringList:
                    fallthrough
                case .string:
                    collected.append(argValue)
                }
                parsed[arg] = collected
            } else {
                print("Invalid Arg: \(arg)")
                error()
            }
        }

        return BasicBuildOptions(podName: podName,
                                 path: parsed["--path"]?.first as? String ?? ".",
                                 userOptions: parsed["--user_option"] as? [String] ?? [],
                                 globalCopts: parsed["--global_copt"] as? [String] ?? [],
                                 trace: parsed["--trace"]?.first as? Bool ?? false,
                                 enableModules: parsed["--enable_modules"]?.first as? Bool ?? false,
                                 generateModuleMap: parsed["--generate_module_map"]?.first as? Bool ?? false,
                                 generateHeaderMap: parsed["--generate_header_map"]?.first as? Bool ?? false,
                                 headerVisibility: parsed["--header_visibility"]?.first as? String ?? "",
                                 alwaysSplitRules: false,
                                 vendorize: parsed["--vendorize"]?.first as? Bool ?? true,
                                 childPaths: parsed["--child_path"] as? [String] ?? []
        )
    }
}

/// Helper code compliments of SO:
/// http://stackoverflow.com/questions/25388747/sha256-in-swift
extension String {
    func sha256() -> String {
        if let stringData = self.data(using: .utf8) {
            return hexStringFromData(input: digest(input: stringData as NSData))
        }
        return ""
    }

    private func digest(input: NSData) -> NSData {
        let digestLength = Int(CC_SHA256_DIGEST_LENGTH)
        var hash = [UInt8](repeating: 0, count: digestLength)
        CC_SHA256(input.bytes, UInt32(input.length), &hash)
        return NSData(bytes: hash, length: digestLength)
    }

    private func hexStringFromData(input: NSData) -> String {
        var bytes = [UInt8](repeating: 0, count: input.length)
        input.getBytes(&bytes, length: input.length)

        var hexString = ""
        for byte in bytes {
            hexString += String(format: "%02x", UInt8(byte))
        }

        return hexString
    }
}

func cacheRoot(forPod pod: String, url: String) -> String {
    return PodStoreCacheDir + pod + "-" + url.sha256() + "/"
}

extension ShellContext {
    func hasDir(_ dirName: String) -> Bool {
        return command("/bin/[", arguments: ["-e", dirName, "]"]).terminationStatus == 0
    }
}

public enum RepoActions {
    /// Initialize a pod repository.
    /// - Get the IPC JSON PodSpec
    /// - Compile a build file based on the PodSpec
    /// - Create a symLinked header structure to support angle bracket includes
    public static func initializeRepository(shell: ShellContext, buildOptions: BuildOptions) {
        let podspecName = CommandLine.arguments[1]
        if buildOptions.path != "." && buildOptions.childPaths.count == 0 {
            // Write an alias BUILD file that points to the source directory
            // this supports naming conventions of //Vendor|external/Podname
            initializeAliasDirectory(shell: shell, podspecName: podspecName,
                buildOptions: buildOptions)
        } else {
            initializePodspecDirectory(shell: shell, podspecName: podspecName,
                buildOptions: buildOptions)
        }
    }

    static func getJSONPodspec(shell: ShellContext, podspecName: String, path: String, childPaths: [String]) -> JSONDict {
        let jsonData: Data

        // Check the path and child paths
        let podspecPath = "\(path)/\(podspecName).podspec"
        let currentDirectoryPath = FileManager.default.currentDirectoryPath
        if FileManager.default.fileExists(atPath: "\(podspecPath).json") {
            jsonData = shell.command("/bin/cat", arguments: [podspecPath + ".json"]).standardOutputData
        } else if FileManager.default.fileExists(atPath: podspecPath) {
            // This uses the current environment's cocoapods installation.
            let whichPod = shell.shellOut("which pod").standardOutputAsString
            if whichPod.isEmpty {
                fatalError("RepoTools requires a cocoapod installation on host")
            }
            let podBin = whichPod.components(separatedBy: "\n")[0]
            let podResult = shell.command(podBin, arguments: ["ipc", "spec", podspecPath])
            guard podResult.terminationStatus == 0 else {
                fatalError("""
                        PodSpec decoding failed \(podResult.terminationStatus)
                        stdout: \(podResult.standardOutputAsString)
                        stderr: \(podResult.standardErrorAsString)
                """)
            }
            jsonData = podResult.standardOutputData
        } else {
            fatalError("Missing podspec ( \(podspecPath) ) inside \(currentDirectoryPath)")
        }

        guard let JSONFile = try? JSONSerialization.jsonObject(with: jsonData, options:
            JSONSerialization.ReadingOptions.allowFragments) as AnyObject,
            let JSONPodspec = JSONFile as? JSONDict
        else {
            fatalError("Invalid JSON Podspec: (look inside \(currentDirectoryPath))")
        }
        return JSONPodspec
    }

    private static func initializeAliasDirectory(shell: ShellContext, podspecName: String,buildOptions: BuildOptions) {
        let visibility = SkylarkNode.functionCall(name: "package",
            arguments: [
                .named(name: "default_visibility",
                       value: .list([.string("//visibility:public")]))
            ])

        let parts = buildOptions.path.split(separator: "/")
        let JSONPodspec = getJSONPodspec(shell: shell, podspecName:
                                      podspecName, path: "../../" + buildOptions.path,
                                      childPaths: buildOptions.childPaths)
        guard let podSpec = try? PodSpec(JSONPodspec: JSONPodspec) else {
            fatalError("Cant read in podspec")
        }
        let buildFile = PodBuildFile.with(podSpec: podSpec, buildOptions:
            buildOptions, assimilate: true)
        
        let getAliasName: (BazelTarget) -> String = {
            target in
            let name = target.name
            let head = buildOptions.podName + "_"
            if head + "acknowledgement" == target.name {
                return target.name
            }
            if let headIdx = name.range(of: head) {
                return String(name[headIdx.upperBound...])
            } else {
                return name
            }
        }

        let actualPath = parts[0] + "/" + parts[1]
        let aliases = buildFile.skylarkConvertibles.compactMap {
            convertible -> SkylarkNode? in
            guard let target = convertible as? BazelTarget else {
                return nil
            }
            guard target.name != "" else {
                return nil
            }
            let name = target.name
            let alias = Alias(name: getAliasName(target),
                actual: "//" + actualPath + ":" + name)
            return alias.toSkylark()
        }

        // Note: we currently have to alias here because header map isn't a
        // BazelTarget
        // TODO: Move ad-hoc bazel targets from ObjcLibrary to BuildFile
        let hmapAliases = buildFile.skylarkConvertibles.compactMap {
            convertible -> SkylarkNode? in
            guard buildOptions.generateHeaderMap,
                let target = convertible as? ObjcLibrary else {
                return nil
            }
            let name = target.name
            let alias = Alias(name: getAliasName(target) + "_hmap",
                actual: "//" + actualPath + ":" + name + "_hmap")
            return alias.toSkylark()
        }

        let lines = [visibility] + aliases + hmapAliases
        let compiler = SkylarkCompiler(lines)
        shell.write(value: compiler.run(), toPath:
            BazelConstants.buildFileURL())
        // assume _PATH_TO_SOME/bin/RepoTools
        let assetRoot = RepoActions.assetRoot(buildOptions: buildOptions)

        shell.dir(PodSupportSystemPublicHeaderDir)
        shell.dir(PodSupportBuidableDir)
        shell.symLink(from: "\(assetRoot)/support.BUILD",
            to: "\(PodSupportBuidableDir)/\(BazelConstants.buildFilePath)")
        let entry = RenderAcknowledgmentEntry(entry: AcknowledgmentEntry(forPodspec: podSpec))
        let acknowledgementFilePath = URL(fileURLWithPath: PodSupportBuidableDir + "acknowledgement.plist")
        shell.write(value: entry, toPath: acknowledgementFilePath)
    }

    private static func writeSpecPrefixHeader(shell: ShellContext, podSpec: PodSpec) {
        if let contents = podSpec.prefixHeaderContents {
            let path = "\(PodSupportDir)/Headers/Private/\(podSpec.name)-prefix.pch"
            shell.write(value: contents, toPath: URL(fileURLWithPath: path))
        }
        podSpec.subspecs.forEach{ writeSpecPrefixHeader(shell: shell, podSpec: $0) }
    }

    private static func writeDefaultPrefixHeader(shell: ShellContext, buildOptions: BuildOptions) {
        let path = "\(PodSupportDir)/Headers/Private/\(buildOptions.podName)-prefix.pch"
        let defaultContents = """
        #ifdef __OBJC__
        #import <UIKit/UIKit.h>
        #else
        #ifndef FOUNDATION_EXPORT
        #if defined(__cplusplus)
        #define FOUNDATION_EXPORT extern "C"
        #else
        #define FOUNDATION_EXPORT extern
        #endif
        #endif
        #endif
        """
        shell.write(value: defaultContents, toPath: URL(fileURLWithPath: path))
    }

    private static func initializePodspecDirectory(shell: ShellContext, podspecName: String,buildOptions: BuildOptions) {
        let workspaceRootPath: String
        if buildOptions.path != "." && buildOptions.childPaths.count == 0 {
            workspaceRootPath = "../..\(buildOptions.path)"
        } else {
            workspaceRootPath =  "."
        }
        shell.dir(PodSupportSystemPublicHeaderDir)
        shell.dir(PodSupportDir + "Headers/Private/")
        shell.dir(PodSupportBuidableDir)

        let JSONPodspec = getJSONPodspec(shell: shell, podspecName:
            podspecName, path: workspaceRootPath,
            childPaths: buildOptions.childPaths)
        var childInfoIter = buildOptions.childPaths.makeIterator()
        // Batch create several symlinks for Pod style includes
        let currentDirectoryPath = FileManager.default.currentDirectoryPath
        var childBuildFiles: [PodBuildFile] = []
        while let childInfo = childInfoIter.next() {
            let childName = childInfo
            guard let childPath = childInfoIter.next() else {
                fatalError("Invalid child path")
            }

            let childBuildOptions = BasicBuildOptions(
                podName: childName,
                path: childPath,
                userOptions: buildOptions.userOptions,
                globalCopts: buildOptions.globalCopts,
                trace: buildOptions.trace,
                enableModules: buildOptions.enableModules,
                generateModuleMap: buildOptions.generateModuleMap,
                generateHeaderMap: buildOptions.generateHeaderMap,
                headerVisibility: buildOptions.headerVisibility,
                alwaysSplitRules: buildOptions.alwaysSplitRules,
                vendorize: buildOptions.vendorize,
                childPaths: buildOptions.childPaths)

            // We need to drop off the childpath passed in. e.g. Vendor/React
            // as the source files in the podspec are relative to the podspec
            let relChildPath = String(childPath.split(separator: "/")
                .dropFirst().dropFirst().joined(separator: "/") )
            let childJSONPodspec = getJSONPodspec(shell: shell, podspecName:
                  childName, path: currentDirectoryPath + "/" + relChildPath,
                  childPaths: buildOptions.childPaths)
            guard let podSpec = try? PodSpec(JSONPodspec: childJSONPodspec) else {
                fatalError("Cant read in podspec")

            }

            writeDefaultPrefixHeader(shell: shell, buildOptions: childBuildOptions)
            writeSpecPrefixHeader(shell: shell, podSpec: podSpec)
            let buildFile = PodBuildFile.with(podSpec: podSpec, buildOptions: childBuildOptions, assimilate: true)
            childBuildFiles.append(buildFile)
        }
        guard let podSpec = try? PodSpec(JSONPodspec: JSONPodspec) else {
            fatalError("Cant read in podspec")
        }
        writeDefaultPrefixHeader(shell: shell, buildOptions: buildOptions)
        writeSpecPrefixHeader(shell: shell, podSpec: podSpec)

        // Create a directory structure condusive to <> imports
        // - Get all of the paths matching wild card imports
        // - Put them into the public header directory
        let buildFile = PodBuildFile.with(podSpec: podSpec, buildOptions: buildOptions)

        // ideally this check should introspec the podspecs value.
        if buildOptions.generateHeaderMap == false {
            var globResults: Set<String> = Set()
            var searchPaths: Set<String> = Set()
            buildFile.skylarkConvertibles.forEach {
                convertible in
                if let lib = convertible as? ObjcLibrary {
                    // Collect all the search paths, there is no per platform header
                    // directories in cocoapods, and do an O(N) operation
                    searchPaths.formUnion(lib.headerName.trivialize(into: Set<String>()) {
                        $0.insert($1)
                    })
                    searchPaths.insert(lib.externalName)
                    searchPaths.insert(lib.name)
                    globResults.formUnion(lib.headers.trivialize(into: Set<String>()) {
                        $0.formUnion($1.sourcesOnDisk())
                    })
                }
                if let fwImport = convertible as? AppleStaticFrameworkImport {
                    globResults.formUnion(fwImport.frameworkImports.trivialize(into: Set<String>()) {
                        accum, next in
                        let HeaderFileTypes = Set([".h", ".hpp", ".hxx"])
                        let imports = next.reduce(into: Set<String>()) {
                            accum, nextImport in
                            accum.formUnion(Set(HeaderFileTypes.map { nextImport + "/**/*" + $0 }))
                        }
                        let headersDir = GlobNode(include: imports)
                        accum.formUnion(headersDir.sourcesOnDisk())
                    })
                }
            }
            searchPaths.forEach {
                searchPath in
                 defer {
                    guard FileManager.default.changeCurrentDirectoryPath(currentDirectoryPath) else {
                        fatalError("Can't change path back to original directory")
                    }
                 }

                let linkPath =   PodSupportSystemPublicHeaderDir + searchPath
                shell.dir(linkPath)
                guard FileManager.default.changeCurrentDirectoryPath(linkPath) else {
                    print("WARNING: Can't change path while creating symlink: " + linkPath)
                    return
                }
                globResults.forEach { globResult in
                    // i.e. pod_support/Headers/Public/__POD_NAME__
                    let from = "../../../../\(globResult)"
                    let to = String(globResult.split(separator: "/").last!)
                    shell.symLink(from: from, to: to)
                }
            }
        }

        // Write out contents of PodSupportBuildableDir

        // Write out the acknowledgement entry plist
        let entry = RenderAcknowledgmentEntry(entry: AcknowledgmentEntry(forPodspec: podSpec))
        let acknowledgementFilePath = URL(fileURLWithPath: PodSupportBuidableDir + "acknowledgement.plist")
        shell.write(value: entry, toPath: acknowledgementFilePath)

        // assume _PATH_TO_SOME/bin/RepoTools
        let assetRoot = RepoActions.assetRoot(buildOptions: buildOptions)

        shell.symLink(from: "\(assetRoot)/support.BUILD",
            to: "\(PodSupportBuidableDir)/\(BazelConstants.buildFilePath)")

        // Write the root BUILD file
        let buildFileSkylarkCompiler = SkylarkCompiler([
            .lines([buildFile.toSkylark()])
        ] + childBuildFiles.map { $0.toSkylark() })
        let buildFileOut = buildFileSkylarkCompiler.run()
        shell.write(value: buildFileOut, toPath:
                BazelConstants.buildFileURL())
    }

    // Assume the directory structure relative to the pod root
    private static func assetRoot(buildOptions: BuildOptions) -> String {
        return "../../../Vendor/rules_pods/BazelExtensions"
    }

    /// Generates a workspace from a Podfile.lock
    public static func generateWorkspace(shell: ShellContext, workspaceOptions: WorkspaceOptions) {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: "Podfile.lock"))
            let lockfile = try Lockfile(data: data)
            let workspace = try PodsWorkspace(lockfile: lockfile, shell: shell)
            let compiler = SkylarkCompiler(workspace.toSkylark())
            print(compiler.run())
        } catch {
            print("Error", error)
        }
    }

    /// Fetch pods from urls.
    /// - Fetch the URL
    /// - Store pod artifacts in the users home directory to prevent
    ///   redundant downloads across bazel repos and cleans.
    /// - Export the requested pod directory into the working directory
    ///
    /// Notes:
    /// We can't use bazel's unarchiving mechanism because it's validation is
    /// incompatible with many pods.
    /// Operations should be atomic
    public static func fetch(shell: ShellContext, fetchOptions: FetchOptions) {
        let podName = fetchOptions.podName
        let urlString = fetchOptions.url
        _ = shell.command(CommandBinary.mkdir, arguments: ["-p", PodStoreCacheDir])

        // Cache Hit
        let podCacheRoot = escape(cacheRoot(forPod: podName, url: urlString))
        if shell.hasDir(podCacheRoot) {
            exportArchive(shell: shell, podCacheRoot: podCacheRoot,
                          fetchOptions: fetchOptions)
            return
        }

        let downloadsDir = shell.tmpdir()
        let url = NSURL(string: urlString)!
        let fileName = url.lastPathComponent!
        let download = downloadsDir + "/" + podName + "-" + fileName
        guard let wwwUrl = NSURL(string: urlString).map({ $0 as URL }),
            shell.download(url: wwwUrl, toFile: download) else {
            fatalError("Download of \(podName) failed")
        }

        // Extract the downloaded archive
        let extractDir = shell.tmpdir()
        func extract() -> CommandOutput {
            let lowercasedFileName = fileName.lowercased()
            if lowercasedFileName.hasSuffix("zip") {
                return shell.command(CommandBinary.sh, arguments: [
                    "-c",
                    unzipTransaction(
                        rootDir: extractDir,
                        fileName: escape(download)
                    ),
                ])
            } else if
                lowercasedFileName.hasSuffix("tar")
                || lowercasedFileName.hasSuffix("tar.gz")
                || lowercasedFileName.hasSuffix("tgz")
            {
                return shell.command(CommandBinary.sh, arguments: [
                    "-c",
                    untarTransaction(
                        rootDir: extractDir,
                        fileName: escape(download)
                    ),
                ])
            }
            fatalError("Cannot extract files other than .zip, .tar, .tar.gz, or .tgz. Got \(lowercasedFileName)")
        }

        assertCommandOutput(extract(), message: "Extraction of \(podName) failed")

        // Save artifacts to cache root
        let export = shell.command("/bin/sh", arguments: [
            "-c",
            "mkdir -p " + extractDir + " && " +
                "cd " + extractDir + " && " +
                "mkdir -p " + podCacheRoot + " && " +
                "mv OUT/* " + podCacheRoot,
        ])
        _ = shell.command(CommandBinary.rm, arguments: ["-rf", extractDir])
        if export.terminationStatus != 0 {
            _ = shell.command(CommandBinary.rm, arguments: ["-rf", podCacheRoot])
            fatalError("Filesystem is in an invalid state")
        }
        exportArchive(shell: shell, podCacheRoot: podCacheRoot,
                      fetchOptions: fetchOptions)
    }

    static func exportArchive(shell: ShellContext, podCacheRoot: String,
                              fetchOptions: FetchOptions) {
        let fileManager = FileManager.default
        let path: String
        let fetchOptionsSubDir = fetchOptions.subDir?.isEmpty == false ?
            fetchOptions.subDir : nil
        if let subDir = fetchOptionsSubDir ?? githubMagicSubDir(fetchOptions: fetchOptions) {
            path = podCacheRoot + subDir
        } else {
            path = podCacheRoot
        }

        _ = shell.command(CommandBinary.ditto, arguments: [path, fileManager.currentDirectoryPath])
    }

    static func githubMagicSubDir(fetchOptions: FetchOptions) -> String? {
        // Github export sugar
        // "https://github.com/facebook/KVOController/archive/v1.1.0.zip"
        // Ends up:
        // v1.1.0.zip
        // After unzipping
        // KVOController-1.1.0
        let testURL = fetchOptions.url.lowercased()
        guard testURL.contains("github") else { return nil }
        let components = testURL.components(separatedBy: "/")
        guard components[components.count - 2] == "archive" else {
            return nil
        }
        var fileName = components[components.count - 1].replacingOccurrences(of: ".zip", with: "")

        // Github tagging
        let unicode = fileName.unicodeScalars
        let secondUnicode = unicode[unicode.index(unicode.startIndex, offsetBy:
                1)]
        if fileName.contains(".")
            && fileName[fileName.startIndex] == "v"
            && CharacterSet.decimalDigits.contains(secondUnicode) {
            fileName = String(fileName[
                fileName.index(fileName.startIndex, offsetBy: 1)...])
        }
        let magicDir = components[components.count - 3] + "-" + fileName
        return magicDir
    }

    static func assertCommandOutput(_ output: CommandOutput, message: String) {
        if output.terminationStatus != 0 {
            fatalError(message)
        }
    }

    // Unzip the entire contents into OUT
    static func unzipTransaction(rootDir: String, fileName: String) -> String {
        return "mkdir -p " + rootDir + " && " +
            "cd " + rootDir + " && " +
            "ditto -x -k --sequesterRsrc --rsrc  " + fileName + " OUT > /dev/null && " +
            "rm -rf " + fileName
    }

    static func untarTransaction(rootDir: String, fileName: String) -> String {
        return "mkdir -p " + rootDir + " && " +
            "cd " + rootDir + " && " +
            "mkdir -p OUT && " +
            "tar -xzvf " + fileName + " -C OUT > /dev/null 2>&1 && " +
            "rm -rf " + fileName
    }
}

