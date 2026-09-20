import AppKit
import CoreImage
import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("usage: render_qr.swift payload output.png\n", stderr)
    exit(2)
}

let payload = CommandLine.arguments[1]
let output = URL(fileURLWithPath: CommandLine.arguments[2])
guard let filter = CIFilter(name: "CIQRCodeGenerator") else { exit(3) }
filter.setValue(Data(payload.utf8), forKey: "inputMessage")
filter.setValue("M", forKey: "inputCorrectionLevel")
guard let image = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { exit(4) }
let context = CIContext()
guard let rendered = context.createCGImage(image, from: image.extent.integral) else { exit(5) }
let bitmap = NSBitmapImageRep(cgImage: rendered)
guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(6) }
try png.write(to: output, options: .atomic)
