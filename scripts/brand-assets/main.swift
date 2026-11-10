import AppKit
import SwiftUI

let root = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
let assets = root.appendingPathComponent("BojiClub/Assets.xcassets")
let exports = root.appendingPathComponent("brand-assets")
try FileManager.default.createDirectory(at:exports,withIntermediateDirectories:true)
func rgb(_ r:CGFloat,_ g:CGFloat,_ b:CGFloat) -> CGColor { CGColor(srgbRed:r,green:g,blue:b,alpha:1) }
func colors(_ variant:String) -> [CGColor] {
    if variant == "mono" { return Array(repeating:rgb(0.10,0.10,0.12),count:4) }
    if variant == "white" { return Array(repeating:rgb(1,1,1),count:4) }
    if variant == "dark" { return [rgb(0.55,0.59,0.65),rgb(0.72,0.80,0.90),rgb(0.53,0.64,0.79),rgb(0.88,0.90,0.94)] }
    return [rgb(0.82,0.83,0.85),rgb(0.72,0.79,0.88),rgb(0.53,0.61,0.73),rgb(0.31,0.33,0.37)]
}
func draw(_ ctx:CGContext,rect:CGRect,variant:String) {
    ctx.saveGState()
    ctx.translateBy(x:rect.minX,y:rect.minY)
    ctx.scaleBy(x:rect.width / BojiLogoGeometry.canvas.width,y:rect.height / BojiLogoGeometry.canvas.height)
    for (i,layer) in BojiLogoGeometry.Layer.allCases.enumerated() { ctx.addPath(BojiLogoGeometry.path(layer));ctx.setFillColor(colors(variant)[i]);ctx.fillPath() }
    ctx.restoreGState()
}
func png(_ path:URL,width:Int,height:Int,opaque:Bool = false,drawBody:(CGContext)->Void) throws {
    let ctx = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x:0,y:CGFloat(height));ctx.scaleBy(x:1,y:-1)
    drawBody(ctx)
    let rep = NSBitmapImageRep(cgImage:ctx.makeImage()!)
    try rep.representation(using:.png,properties:[:])!.write(to:path)
}
func pdf(_ path:URL,variant:String,size:CGFloat) {
    var bounds=CGRect(x:0,y:0,width:size,height:size)
    let consumer=CGDataConsumer(url:path as CFURL)!
    let ctx=CGContext(consumer:consumer,mediaBox:&bounds,nil)!
    ctx.beginPDFPage(nil);ctx.translateBy(x:0,y:size);ctx.scaleBy(x:1,y:-1)
    draw(ctx,rect:CGRect(x:size*0.03,y:0,width:size*0.94,height:size),variant:variant)
    ctx.endPDFPage();ctx.closePDF()
}
let appIcon=assets.appendingPathComponent("AppIcon.appiconset")
var icons:[[String:Any]]=[]
for variant in ["light","dark","mono"] {
    let filename="AppIcon-Boji-\(variant).png"
    try png(appIcon.appendingPathComponent(filename),width:1024,height:1024,opaque:true) { ctx in
        ctx.setFillColor(variant == "dark" ? rgb(0.075,0.085,0.10) : rgb(0.985,0.987,0.992));ctx.fill(CGRect(x:0,y:0,width:1024,height:1024))
        draw(ctx,rect:CGRect(x:208,y:174,width:608,height:664),variant:variant)
    }
    var entry:[String:Any] = ["filename":filename,"idiom":"universal","platform":"ios","size":"1024x1024"]
    if variant != "light" { entry["appearances"]=[["appearance":"luminosity","value":variant == "dark" ? "dark" : "tinted"]] }
    icons.append(entry)
}
try JSONSerialization.data(withJSONObject:["images":icons,"info":["author":"xcode","version":1]],options:[.prettyPrinted,.sortedKeys]).write(to:appIcon.appendingPathComponent("Contents.json"))
for variant in ["light","dark","mono","white"] {
    pdf(exports.appendingPathComponent("BojiMark-\(variant).pdf"),variant:variant,size:256)
    try png(exports.appendingPathComponent("BojiMark-\(variant).png"),width:512,height:512) { ctx in
        draw(ctx,rect:CGRect(x:16,y:0,width:480,height:512),variant:variant)
    }
}
let launch=assets.appendingPathComponent("BojiLaunchMark.imageset");try FileManager.default.createDirectory(at:launch,withIntermediateDirectories:true)
for variant in ["light","dark"] { pdf(launch.appendingPathComponent("BojiLaunch-\(variant).pdf"),variant:variant,size:96) }
try JSONSerialization.data(withJSONObject:["images":[["filename":"BojiLaunch-light.pdf","idiom":"universal"],["filename":"BojiLaunch-dark.pdf","idiom":"universal","appearances":[["appearance":"luminosity","value":"dark"]]]],"info":["author":"xcode","version":1],"properties":["preserves-vector-representation":true]],options:[.prettyPrinted,.sortedKeys]).write(to:launch.appendingPathComponent("Contents.json"))
// Review board is rendered from the same vector paths, with no source-image pixel edits.
try png(exports.appendingPathComponent("Brand-Variants.png"),width:1200,height:600) { ctx in
    ctx.setFillColor(rgb(0.98,0.98,0.99));ctx.fill(CGRect(x:0,y:0,width:600,height:600))
    ctx.setFillColor(rgb(0.075,0.085,0.10));ctx.fill(CGRect(x:600,y:0,width:600,height:600))
    draw(ctx,rect:CGRect(x:144,y:58,width:312,height:340),variant:"light")
    draw(ctx,rect:CGRect(x:744,y:58,width:312,height:340),variant:"dark")
    for (i,size) in [16.0,24.0,48.0,72.0].enumerated() {
        draw(ctx,rect:CGRect(x:100+Double(i)*112,y:480,width:size,height:size),variant:"mono")
        draw(ctx,rect:CGRect(x:700+Double(i)*112,y:480,width:size,height:size),variant:"white")
    }
}
// Export an editable SVG from the exact same CGPath master.
var svg="<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 640 680\"><title>BOJI CLUB</title>"
for (i,layer) in BojiLogoGeometry.Layer.allCases.enumerated() {
    var commands=""
    BojiLogoGeometry.path(layer).applyWithBlock { element in
        let e=element.pointee,p=e.points
        switch e.type {
        case .moveToPoint:commands += "M\(p[0].x) \(p[0].y) "
        case .addLineToPoint:commands += "L\(p[0].x) \(p[0].y) "
        case .addCurveToPoint:commands += "C\(p[0].x) \(p[0].y) \(p[1].x) \(p[1].y) \(p[2].x) \(p[2].y) "
        case .addQuadCurveToPoint:commands += "Q\(p[0].x) \(p[0].y) \(p[1].x) \(p[1].y) "
        case .closeSubpath:commands += "Z "
        @unknown default:break
        }
    }
    let fill=["#D1D4D9","#B8C9E0","#879CBA","#4F545E"][i]
    svg += "<path d=\"\(commands)\" fill=\"\(fill)\"/>"
}
try (svg+"</svg>\n").write(to:exports.appendingPathComponent("BojiMark-Master.svg"),atomically:true,encoding:.utf8)
print("BRAND_ASSETS_RENDERED")

for variant in ["light","dark","mono","white"] {
    var value=svg+"</svg>\n"
    let originals=["#D1D4D9","#B8C9E0","#879CBA","#4F545E"]
    for (i,color) in colors(variant).enumerated() {
        let c=color.components!
        let fill=String(format:"#%02X%02X%02X",Int((c[0]*255).rounded()),Int((c[1]*255).rounded()),Int((c[2]*255).rounded()))
        value=value.replacingOccurrences(of:originals[i],with:fill)
    }
    try value.write(to:exports.appendingPathComponent("BojiMark-\(variant).svg"),atomically:true,encoding:.utf8)
}
