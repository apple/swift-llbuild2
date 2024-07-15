# llbuild2fx tutorial

See also `CachedKeyTests.testHTTP`.


## What is llbuild2fx?

llbuild2fx is the memoization engine that heavily embraces an underlying content-addressible storage. This makes it a suitale primitive for distributed build systems.

With llbuild2fx you can break up a complex computation into into interdependent memoizable/cachable units called “Keys”.

A key has the following structure:

```swift
public struct MyExampleKeyResult: Codable {
    let myExampleValue: String
}

extension MyExampleKeyResult: FXValue {}

public struct FetchTitle: AsyncFXKey, Encodable {
    public typealias ValueType = MyExampleKeyResult

    public static let versionDependencies: [FXVersioning.Type] = [ ... ]

    let someInputParameter: String

    public init(someInputParameter: String) {
        self.someInputParameter = someInputParameter
    }

    public func computeValue(
        _ fi: FXFunctionInterface<Self>, // A mechanism to dynamically request for other keys
        _ ctx: Context
    ) async throws -> MyExampleKeyResult {
        // ...
        let results = try await fi.request(SomeOtherKey(url: url), ctx)
        // ...
        return MyExampleKeyResult(myExampleValue: results.blah)
    }
}
```

## Examples

### A web crawler

Suppose you are a solo-entrepreneur and you want to implement a web crawler that fetches the title of a bunch of web pages.

#### **Example 1: Fetch titles**

You can implement a single `FetchTitle` key, but lets decouple it into two keys: `FetchHTTP` and `FetchTitle` .


```swift
public struct FetchTitleResult: Codable {
    let pageTitle: String
}

extension FetchTitleResult: FXValue {}

public struct FetchTitle: AsyncFXKey, Encodable {
    public typealias ValueType = FetchTitleResult

    public static let versionDependencies: [FXVersioning.Type] = [FetchHTTP.self]

    let url: String

    public init(url: String) {
        self.url = url
    }

    public func computeValue(_ fi: FXFunctionInterface<Self>, _ ctx: Context) async throws -> FetchTitleResult {
        let str = try await fi.request(FetchHTTP(url: url), ctx).body

        let results = try RegEx(pattern: "<title>(.*)</title>").matchGroups(in: str)
        print(results)
        if let pageTitle = results.first?.first {
            return FetchTitleResult(pageTitle: pageTitle)
        } else {
            throw StringError("unhandled scenario")
        }
    }
}
```

and

```swift
public struct FetchHTTPResult: Codable {
    let body: String
}

extension FetchHTTPResult: FXValue {}

public struct FetchHTTP: AsyncFXKey, Encodable {
    public typealias ValueType = FetchHTTPResult

    public static let version: Int = 2
    public static let versionDependencies: [FXVersioning.Type] = []

    let url: String

    public init(url: String) {
        self.url = url
    }

    public func computeValue(_ fi: FXFunctionInterface<Self>, _ ctx: Context) async throws -> FetchHTTPResult {
        let client = LLBCASFSClient(ctx.db)

        let request = HTTPClientRequest(url: self.url)
        let response = try await HTTPClient.shared.execute(request, timeout: .seconds(30))

        if response.status == .ok {
            let body = try await response.body.collect(upTo: 1024 * 1024) // 1 MB
            let str = String(buffer: body)
            return FetchHTTPResult(body: str)
        } else {
            throw StringError("response.status was not ok (\(response.status))")
        }
        throw StringError("unhandled scenario")
    }
}
```

This is how you would write a test for it:

```swift

final class CachedKeyTests: XCTestCase {
    func testHTTP() async throws {
        let ctx = Context()
        let group = LLBMakeDefaultDispatchGroup()

        // let db = LLBInMemoryCASDatabase(group: group)
        let db = LLBFileBackedCASDatabase(group: group, path: AbsolutePath("/tmp/my-cas/cas"))

        let functionCache = LLBFileBackedFunctionCache(group: group, path: AbsolutePath("/tmp/my-cas/function-cache"), version: "0")

        let executor = FXLocalExecutor()

        let engine = FXBuildEngine(
            group: group,
            db: db,
            functionCache: functionCache,
            executor: executor
        )
        let results = try await engine.build(key: FetchTitle(url: "http://example.com/"), ctx).get()
        XCTAssertEqual(results.pageTitle, "Example Domain")
    }
}
```

#### **🚧 Example 2: Fetch image URLS + Fetch image blobs**

Your solo business is doing great and you want to ship a new functionality. You want to extend your crawler to extract the list of all images from the HTML. At this point you can disconnect from the internet and rely on the fact that `FetchHTTP` is already memoized. If you want to implement `FetchListOfImages` on the airplane, you have the option to do so. llbuild2fx has populated the CAS with the right objects. On top of that it has populated the function cache, which maps already-computed keys to objects in CAS.

Here is how you would implement `FetchListOfImages` and write a test for it:

```
TBD
```

### Decoupling “what” from “how”: A top-level “Build” key

```swift
public struct BuildResult: Codable {
    let result: TypedBuildResult
}

extension BuildResult: FXValue {}

public enum TypedBuildResult: Codable {
    case txtFile(DataID)
    case tarFile(DataID)
}

public struct Build: AsyncFXKey, Encodable {
    public typealias ValueType = BuildResult

    public static let version: Int = 1
    public static let versionDependencies: [FXVersioning.Type] = [Build.self]

    let goal: String

    public func computeValue(_ fi: FXFunctionInterface<Self>, _ ctx: Context) async throws -> BuildResult {
        if goal == "release.txt" {
            // Fetch release.txt via HTTP
        } else if goal == "release.tar" {
            // ...
        } else if goal == "foo.html" {
            // ...
        } else if goal == "bar.png" {
            // ...
        } else if goal.hasPrefix("http://") {
            // ...
        }
    }
}
```

### 🚧 Example 3:  Shake’s release.tar example

Another illuminating example is Shake's `release.tar` example. Consider either of these scenarios:

* suppose you are implementing a static site generator, and as part of a final step, you want to create a tar file and scp+untar it to a remote server.
* suppose you maintain an open source project and  you want to release sources for the most recent version as a tar file on web. Two important observations:
    * the list of files to be included in the final compressed file is listed in `release.txt` (which can itself be dynamically generated)
    * a file listed in `release.txt` may not be a leaf file and needs to be “built” on the fly.

Here’s how you would express this in Shake:

```haskell
import Development.Shake
import Development.Shake.FilePath

main = shakeArgs shakeOptions $ do
    want ["result.tar"] -- (1)
    "*.tar" %> \out -> do -- (2)
        contents <- readFileLines $ out -<.> "txt" -- (3)
        need contents -- (4)
        cmd "tar -cf" [out] contents -- (5)
```

The above snippet says

* (1) We are interested in obtaining `result.tar`
* (2) Then it defines a rule for any target that ends with `.tar` extension
    * In the body of the rule, (3) it reads content of a `txt` file with the same prefix and (4) dynamically declares dependency via `need contents`
        * This may trigger building artifacts that match other rules
    * (5) Once the dependencies are met, it spawns `tar -cf` passing all the paths it as CLI arg

Here’s how it looks like in llbuild2fx:

```swift
public struct BuildReleaseTarResult {
    releaseTarID: DataID
}

extension BuildReleaseTarResult: FXValue {}

public struct BuildReleaseTar: AsyncFXKey, Encodable { // (2)
    public typealias ValueType = BuildReleaseTarResult

    public static let version: Int = 2
    public static let versionDependencies: [FXVersioning.Type] = [Build.self]

    let releaseDotTxt: DataID // (3)

    public func computeValue(_ fi: FXFunctionInterface<Self>, _ ctx: Context) async throws -> BuildReleaseTarResult {
        // Use CAS APIs to read contents of release.txt

        // Request for contens of release.txt to be built via `fi.request(Build(...))`

        // In Shake you rely on the rule system or file system primitives to read/build release.txt
        // In llbuild2fx you typically pass CAS ID of the source folder (or release.txt) as input argument
        // If release.txt is something that another key produces it, you would use
        // fi.request(..., ctx) to obtain its CAS ID.
        // (e.g. you may want to use FetchHTTP to download release.txt from a remote source.)

        // (4) Dynamically declares dependency via fi.request
        // This will trigger building other keys (which may already be in function cache)
        let ids = releaseTxt.lines.asyncMap { line in
            try await fi.request(Build(line), ctx).get() // (4)
        }

        // (5) Once the dependencies are met, it spawns tar -cf passing all the paths it as CLI arg
        // TBD

    }
}
```

And here is a test for it

```swift
final class CachedKeyTests: XCTestCase {
    func testHTTP() async throws {
        // Populate the content of release.txt
        // TBD.

        let results = try await engine.build(key: Build(goal: "release.tar"), ctx).get()

        // Extract the tar file and get the list of contents
        XCTAssertEqual(results.pageTitle, "Example Domain")
    }
}
```

### Example project ideas for llbuild2fx

* Map/Reduce cache hits from build logs
* Game of Life
    * We need to port Sergio’s pre-llbuild2fx GUI example to llbuild2fx
* CASLisp

### The FXLocalExecutor abstraction

TBD.

## Background

The core reason why llbuild2fx is powerful is its reliance on content-addressable storage. Think of a tree where each node has a checksum. For each labeled node, the checksum is computed by putting together the checksum of the label, and aggregating the checksum of the children.

You get 3 main things for free when you express your computations via llbuild2fx:

* **(Diskless, with no extra process spawns)** You can implement in-memory commands, with little reliance on the filesystem.
* **(Memoization)** Especially if your workflows require a lot of tree transformations, expressing them as CAS transformations saves you tons of slow interactions with disk, because CAS and memoization work great together.
* **(Flexible function interface)** You get a dynamic dependency graph by the virtue of defining keys that request for other keys.
    * An existing system that is *really good* at dynamic dependency graphs is Shake. llbuild2fx keys are somewhat comparable to Shake actions. But Shake (as described in [the original ICFP'12 paper](https://dl.acm.org/doi/pdf/10.1145/2398856.2364538)) does not rely on CAS (i.e. it doesn’t yield itself nicely to cloud builds)
