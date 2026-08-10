import Foundation

@main
struct CLI {
    static func main() async {
        let report = await PreflightChecker.run(ipsw: nil, targetDirectory: DefaultLocations.poc, queryLatestSupported: false)
        print(report.text)
    }
}
