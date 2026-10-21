// Rebuild the approved Signal Planes artwork without third-party libraries.
// Usage: swift script/BrandAssetExport.swift <ResolveScopes project root>
import Foundation
import CoreGraphics
import ImageIO

let root=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
let brand=root.appendingPathComponent("Branding/SignalPlanes",isDirectory:true)
let pad=root.appendingPathComponent("iPadCompanion/ResolveScopesPad/Assets.xcassets",isDirectory:true)
let fm=FileManager.default
for folder in [brand,pad] {try fm.createDirectory(at:folder,withIntermediateDirectories:true)}
let bars:[CGRect]=[
    CGRect(x:40,y:72,width:40,height:48),CGRect(x:40,y:144,width:40,height:48),
    CGRect(x:108,y:40,width:40,height:56),CGRect(x:108,y:120,width:40,height:96),
    CGRect(x:176,y:64,width:40,height:80),CGRect(x:176,y:168,width:40,height:24)
]
func rgb(_ r:Int,_ g:Int,_ b:Int)->CGColor {CGColor(colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!,components:[CGFloat(r)/255,CGFloat(g)/255,CGFloat(b)/255,1])!}
let mint=rgb(0x67,0xD8,0xC4)
let charcoal=rgb(0x19,0x19,0x19)
func writeJSON(_ value:Any,_ file:URL)throws {
    try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]).write(to:file)
}
func render(_ file:URL,size:Int,color:CGColor,tile:String?=nil)throws {
    let opaque=tile == "ipad"
    let info=opaque ? CGImageAlphaInfo.noneSkipLast:CGImageAlphaInfo.premultipliedLast
    guard let ctx=CGContext(data:nil,width:size,height:size,bitsPerComponent:8,bytesPerRow:size*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:info.rawValue) else {fatalError("bitmap context")}
    ctx.translateBy(x:0,y:CGFloat(size));ctx.scaleBy(x:CGFloat(size)/1024,y:-CGFloat(size)/1024)
    if let tile {
        ctx.setFillColor(charcoal)
        if tile == "mac" {ctx.addPath(CGPath(roundedRect:CGRect(x:64,y:64,width:896,height:896),cornerWidth:200,cornerHeight:200,transform:nil));ctx.fillPath()}
        else {ctx.fill(CGRect(x:0,y:0,width:1024,height:1024))}
        ctx.translateBy(x:102.4,y:102.4);ctx.scaleBy(x:3.2,y:3.2)
    }else {ctx.scaleBy(x:4,y:4)}
    ctx.setFillColor(color);for rect in bars {ctx.fill(rect)}
    guard let image=ctx.makeImage(),let output=CGImageDestinationCreateWithURL(file as CFURL,"public.png" as CFString,1,nil) else {fatalError("PNG writer")}
    CGImageDestinationAddImage(output,image,nil);precondition(CGImageDestinationFinalize(output))
}
for (name,hex,color) in [("mint","#67D8C4",mint),("white","#FFFFFF",rgb(255,255,255)),("black","#111111",rgb(17,17,17))] {
    let rectangles=bars.map{"<rect x=\"\(Int($0.minX))\" y=\"\(Int($0.minY))\" width=\"\(Int($0.width))\" height=\"\(Int($0.height))\"/>"}.joined()
    let svg="<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 256 256\" role=\"img\"><title>ResolveScopes Signal Planes</title><g fill=\"\(hex)\">\(rectangles)</g></svg>\n"
    try svg.write(to:brand.appendingPathComponent("ResolveScopes-mark-\(name).svg"),atomically:true,encoding:.utf8)
    try render(brand.appendingPathComponent("ResolveScopes-mark-\(name).png"),size:1024,color:color)
}
for platform in ["mac","ipad"] {try render(brand.appendingPathComponent("ResolveScopes-\(platform)-1024.png"),size:1024,color:mint,tile:platform)}
let iconset=brand.appendingPathComponent("ResolveScopes.iconset",isDirectory:true)
try fm.createDirectory(at:iconset,withIntermediateDirectories:true)
for size in [16,32,128,256,512] {
    for scale in [1,2] {try render(iconset.appendingPathComponent("icon_\(size)x\(size)\(scale==2 ? "@2x":"").png"),size:size*scale,color:mint,tile:"mac")}
}
let markset=pad.appendingPathComponent("ResolveScopesMark.imageset",isDirectory:true)
let appset=pad.appendingPathComponent("AppIcon.appiconset",isDirectory:true)
for folder in [markset,appset] {try fm.createDirectory(at:folder,withIntermediateDirectories:true)}
let metadata:[String:Any] = ["version":1,"author":"xcode"]
try writeJSON(["info":metadata],pad.appendingPathComponent("Contents.json"))
var marks=[[String:String]]()
for scale in [1,2,3] {
    let name="mark@\(scale)x.png"
    try render(markset.appendingPathComponent(name),size:64*scale,color:mint)
    marks.append(["idiom":"universal","scale":"\(scale)x","filename":name])
}
try writeJSON(["images":marks,"info":metadata],markset.appendingPathComponent("Contents.json"))
var icons=[[String:String]]()
for (points,scales) in [("20",[1,2]),("29",[1,2]),("40",[1,2]),("76",[1,2]),("83.5",[2])] {
    for scale in scales {
        let pixels=Int(Double(points)!*Double(scale)),name="ipad-\(pixels).png"
        try render(appset.appendingPathComponent(name),size:pixels,color:mint,tile:"ipad")
        icons.append(["idiom":"ipad","size":"\(points)x\(points)","scale":"\(scale)x","filename":name])
    }
}
let marketing="app-store-1024.png"
try render(appset.appendingPathComponent(marketing),size:1024,color:mint,tile:"ipad")
icons.append(["idiom":"ios-marketing","size":"1024x1024","scale":"1x","filename":marketing])
try writeJSON(["images":icons,"info":metadata],appset.appendingPathComponent("Contents.json"))
print("Signal Planes: SVG/PNG masters, Mac iconset and iPad asset catalog exported")
