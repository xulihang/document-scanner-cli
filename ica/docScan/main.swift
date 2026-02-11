//
//  main.swift
//  docScan
//
//  Created by xulihang on 2025/7/28.
//

import Foundation
import ImageCaptureCore
import AppKit


class ScannerManager: NSObject, ICDeviceBrowserDelegate, ICScannerDeviceDelegate {
    struct DocumentSize {
        let type: ICScannerDocumentType
        let width: CGFloat  // 短边
        let height: CGFloat // 长边
        
        // 判断是否匹配（考虑容差和方向）
        func matches(width: CGFloat, height: CGFloat, tolerance: CGFloat = 2.0) -> Bool {
            let w = min(width, height)
            let h = max(width, height)
            return abs(self.width - w) <= tolerance && abs(self.height - h) <= tolerance
        }
    }
    let supportedDocumentTypes: [DocumentSize] = [
        DocumentSize(type: .typeA4, width: 210.0, height: 297.0),
        DocumentSize(type: .typeUSLetter, width: 215.9, height: 279.4),    // 8.5 × 11 in
        DocumentSize(type: .typeUSLegal, width: 215.9, height: 355.6),     // 8.5 × 14 in
        DocumentSize(type: .typeA3, width: 297.0, height: 420.0),
        DocumentSize(type: .typeA5, width: 148.0, height: 210.0),
        DocumentSize(type: .typeA6, width: 105.0, height: 148.0),
        DocumentSize(type: .typeB5, width: 176.0, height: 250.0),
        DocumentSize(type: .typeUSExecutive, width: 184.2, height: 266.7), // 7.25 × 10.5 in
        DocumentSize(type: .typeJISB4, width: 257.0, height: 364.0),
        DocumentSize(type: .typeJISB6, width: 128.0, height: 182.0),
        DocumentSize(type: .typeA2, width: 420.0, height: 594.0),
        DocumentSize(type: .typeA1, width: 594.0, height: 841.0),
        DocumentSize(type: .typeA0, width: 841.0, height: 1189.0)
    ]
    func detectDocumentType(width: CGFloat, height: CGFloat) -> ICScannerDocumentType {
        // 先尝试匹配标准尺寸
        for size in supportedDocumentTypes {
            if size.matches(width: width, height: height) {
                return size.type
            }
        }
        
        // 未匹配到标准尺寸时的降级策略：
        // 1. 根据面积判断大致范围
        let area = width * height
        
        if area > 100000 { // > A3
            return .typeA3
        } else if area > 40000 { // A3 ~ A4 之间
            return .typeA4
        } else if area > 20000 { // A4 ~ A5 之间
            return .typeA5
        } else {
            return .typeA6
        }
    }
    
    func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {
        print("did close")
    }
    
    func didRemove(_ device: ICDevice) {
        print("did remove")
    }
    
    func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {
        print("did open")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self = self else { return }
            guard let scanner = currentScanner else { return }
            
            scanner.transferMode = .fileBased
            
            if targetURL?.hasDirectoryPath ?? false {
                scanner.downloadsDirectory = targetURL!
            }else{
                scanner.downloadsDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            }
            
            scanner.documentName = "scanned"
            scanner.documentUTI = kUTTypeJPEG as String
            if let functionalUnit = scanner.selectedFunctionalUnit as? ICScannerFunctionalUnit {
                let resolutionIndex = functionalUnit.supportedResolutions.integerGreaterThanOrEqualTo(desiredResolution) ?? functionalUnit.supportedResolutions.last
                if let resolutionIndex = resolutionIndex ?? functionalUnit.supportedResolutions.last {
                    functionalUnit.resolution = resolutionIndex
                }
                var hasFeeder = false
                
                let a4Width: CGFloat = 210.0 // mm
                let a4Height: CGFloat = 297.0 // mm
                let widthInPoints = a4Width * 72.0 / 25.4 // convert to point
                let heightInPoints = a4Height * 72.0 / 25.4
                
                if let feederFunctionalUnit = functionalUnit as? ICScannerFunctionalUnitDocumentFeeder {
                    print("feeder supported")
                    hasFeeder = true
                    feederFunctionalUnit.documentType = detectDocumentType(width: a4Width, height: a4Height)
                }
                
                if hasFeeder == false {
                    print("setting scan area")
                    functionalUnit.scanArea = NSMakeRect(0, 0, widthInPoints, heightInPoints)
                }
                
                functionalUnit.pixelDataType = pixelDataType
                if pixelDataType == ICScannerPixelDataType.BW {
                    functionalUnit.bitDepth = .depth1Bit
                }else {
                    functionalUnit.bitDepth = .depth8Bits
                }
                        
                

                scanner.requestScan()
            }
        }
    }
    
    private var deviceBrowser: ICDeviceBrowser!
    private var scanners: [ICScannerDevice] = []
    private var currentScanner: ICScannerDevice?
    private var desiredResolution:Int = 300
    private var pixelDataType:ICScannerPixelDataType = ICScannerPixelDataType.RGB
    private var scanCompletionHandler: ((Result<URL, Error>) -> Void)?
    private var targetURL: URL?
    
    override init() {
        super.init()
        setupDeviceBrowser()
    }
    
    private func setupDeviceBrowser() {
        deviceBrowser = ICDeviceBrowser()
        deviceBrowser.delegate = self
        let mask = ICDeviceTypeMask(rawValue:
                    ICDeviceTypeMask.scanner.rawValue |
                    ICDeviceLocationTypeMask.local.rawValue |
                    ICDeviceLocationTypeMask.bonjour.rawValue |
                    ICDeviceLocationTypeMask.shared.rawValue)
        deviceBrowser.browsedDeviceTypeMask = mask!
        deviceBrowser.start()
    }
    
    func listScanners(completion: @escaping ([ICScannerDevice]) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            completion(self.scanners)
        }
    }
    
    // MARK: - ICScannerDeviceDelegate
    
    func scannerDevice(_ scanner: ICScannerDevice, didScanTo url: URL) {
        print("did scan to")
        print(url.absoluteString)
        if targetURL?.hasDirectoryPath ?? false {
           return
        }
        guard let targetURL = targetURL else {
            scanCompletionHandler?(.failure(NSError(domain: "ScannerError", code: -2, userInfo: [NSLocalizedDescriptionKey: "No target URL set"])))
            return
        }
        do {
            try FileManager.default.moveItem(at: url, to: targetURL)
            scanCompletionHandler?(.success(targetURL))
        } catch {
            scanCompletionHandler?(.failure(error))
        }
    }
    
    func scannerDevice(_ scanner: ICScannerDevice, didCompleteScanWithError: (any Error)?) {
        print("scan completed")
        if didCompleteScanWithError == nil {
            scanCompletionHandler?(.success(targetURL!))
        }else{
            scanCompletionHandler?(.failure(didCompleteScanWithError!))
        }
    }
    
    // MARK: - Scan Operations
    
    func startScan(scanner: ICScannerDevice,resolution: Int,colorMode:String, outputPath: String, completion: @escaping (Result<URL, Error>) -> Void) {
        currentScanner = scanner
        desiredResolution = resolution
        scanCompletionHandler = completion
        
        if colorMode.lowercased() == "color" {
            pixelDataType = ICScannerPixelDataType.RGB
        }else if colorMode.lowercased() == "lineart" {
            pixelDataType = ICScannerPixelDataType.BW
        }else if colorMode.lowercased() == "grayscale" {
            pixelDataType = ICScannerPixelDataType.gray
        }
        
        targetURL = URL(fileURLWithPath: outputPath)
        
        scanner.delegate = self
        scanner.requestOpenSession()

    }
    
    // MARK: - ICDeviceBrowserDelegate
    
    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let scanner = device as? ICScannerDevice else { return }
        scanners.append(scanner)
    }
    
    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        if let index = scanners.firstIndex(where: { $0 == device }) {
            scanners.remove(at: index)
        }
    }
}

func main() {
    let scannerManager = ScannerManager()
    // Parse command line arguments
    var outputPath: String?
    var listScannersFlag = false
    var selectedScannerName: String?
    var colorMode: String?
    var resolution: String = "200"
    let arguments = CommandLine.arguments
    for i in 0..<arguments.count {
        switch arguments[i] {
        case "-o", "--output":
            if i+1 < arguments.count {
                outputPath = arguments[i+1]
            }
        case "-r", "--resolution":
            if i+1 < arguments.count {
                resolution = arguments[i+1]
            }
        case "-m", "--mode":
            if i+1 < arguments.count {
                colorMode = arguments[i+1]
            }
        case "-L":
            listScannersFlag = true
        case "-d":
            if i+1 < arguments.count {
                selectedScannerName = arguments[i+1]
            } else {
                print("Error: -d requires a scanner name argument")
                exit(1)
            }
        default:
            break
        }
    }
    
    // Handle -L flag to list scanners
    if listScannersFlag {
        scannerManager.listScanners { scanners in
            if scanners.isEmpty {
                print("No scanners available.")
            } else {
                print("Available scanners:")
                for (index, scanner) in scanners.enumerated() {
                    print("\(index): \(scanner.name ?? "Unknown Scanner")")
                }
            }
            exit(0)
        }
        RunLoop.current.run()
        return
    }
    
    // Check required parameters
    if outputPath == nil {
        print("Usage: docScan [options]")
        print("Options:")
        print("  -L                List all available scanners")
        print("  -d <name>         Specify scanner by name")
        print("  -m <mode>         Specify color mode")
        print("  -r <resolution>   Specify resolution")
        print("  -o <path>         Output file path")
        exit(1)
    }
    
    scannerManager.listScanners { scanners in
        if scanners.isEmpty {
            print("No scanners found.")
            exit(1)
        }
        
        // Find the scanner with matching name
        guard var selectedScanner = scanners.first else {
            print("No scanners not found.")
            exit(1)
        }
        
        if selectedScannerName != "" {
            for scanner in scanners {
                if scanner.name == selectedScannerName {
                    selectedScanner = scanner
                    break
                }
            }
        }
        
        print("Selected scanner: \(selectedScanner.name ?? "Unknown")")
        let resInt:Int = Int(resolution) ?? 200
        scannerManager.startScan(scanner: selectedScanner,resolution: resInt,colorMode: colorMode ?? "color", outputPath: outputPath!) { result in
            switch result {
            case .success(let url):
                print("Scan successfully saved to: \(url.path)")
            case .failure(let error):
                print("Scan failed: \(error.localizedDescription)")
            }
            exit(0)
        }
    }
    
    RunLoop.current.run()
}

main()
