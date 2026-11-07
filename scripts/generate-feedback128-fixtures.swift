import Foundation
import AVFoundation
import CoreVideo
let folder=CommandLine.arguments[1]
for (name,frames,fps) in [("fixture.mp4",10,10),("long.mp4",62,1)] {
 let url=URL(fileURLWithPath:folder).appendingPathComponent(name);try? FileManager.default.removeItem(at:url)
 let w=try AVAssetWriter(outputURL:url,fileType:.mp4)
 let i=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:64,AVVideoHeightKey:64]);i.expectsMediaDataInRealTime=false
 let a=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:i,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32ARGB,kCVPixelBufferWidthKey as String:64,kCVPixelBufferHeightKey as String:64])
 w.add(i);guard w.startWriting() else{fatalError("writer")};w.startSession(atSourceTime:.zero)
 for n in 0..<frames {
  while !i.isReadyForMoreMediaData{Thread.sleep(forTimeInterval:0.005)}
  var p:CVPixelBuffer?;CVPixelBufferCreate(kCFAllocatorDefault,64,64,kCVPixelFormatType_32ARGB,nil,&p)
  guard let p else{fatalError("pixel")};CVPixelBufferLockBaseAddress(p,[]);memset(CVPixelBufferGetBaseAddress(p),170,CVPixelBufferGetDataSize(p));CVPixelBufferUnlockBaseAddress(p,[])
  guard a.append(p,withPresentationTime:CMTime(value:Int64(n),timescale:Int32(fps))) else{fatalError("append")}
 }
 w.endSession(atSourceTime:CMTime(value:Int64(frames),timescale:Int32(fps)));i.markAsFinished()
 let done=DispatchSemaphore(value:0);w.finishWriting{done.signal()};done.wait();guard w.status == .completed else{fatalError("finish")};print(name)
}
