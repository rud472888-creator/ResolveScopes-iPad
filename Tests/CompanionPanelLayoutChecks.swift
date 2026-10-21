import Foundation
import CoreGraphics
@main struct LayoutCheck {
 static func main() {
  var checks=0
  for size in [CGSize(width:1376,height:760),CGSize(width:1024,height:1000),CGSize(width:500,height:500),CGSize(width:340,height:420)] {
   for style in CompanionLayoutStyle.allCases {
    for main in [0,2,4] {
     let plan=CompanionPanelLayout.make(size:size,panelCount:5,style:style,columns:2,featured:main)
     let expected=style.smallCount.map{$0+1} ?? 5
     precondition(plan.items.count==expected)
     precondition(Set(plan.items.map(\.id)).count==expected)
     for item in plan.items {
      precondition(item.frame.width>0 && item.frame.height>=150)
      precondition(item.frame.minX>=0 && item.frame.maxX<=size.width+0.01)
      precondition(item.frame.minY>=0 && item.frame.maxY<=plan.contentHeight+0.01)
      for other in plan.items where other.id != item.id {precondition(!item.frame.intersects(other.frame))}
     }
     if style != .grid {
      let top=plan.items[0];precondition(top.id==main && top.frame.width==size.width-16)
      precondition(plan.items.dropFirst().allSatisfy{$0.frame.minY>top.frame.maxY})
      if size.width==1376 {precondition(plan.items.dropFirst().allSatisfy{$0.frame.minY==plan.items[1].frame.minY})}
     }
     let solo=CompanionPanelLayout.make(size:size,panelCount:5,style:style,columns:2,featured:main,solo:4)
     precondition(solo.items.count==1 && solo.items[0].id==4)
     let restored=CompanionPanelLayout.make(size:size,panelCount:5,style:style,columns:2,featured:main)
     precondition(restored.items.map(\.id)==plan.items.map(\.id))
     checks+=1
    }
   }
  }
  let source=CompanionPanelLayout.make(size:.init(width:1376,height:760),panelCount:5,style:.largeWithThree,columns:3,featured:4,sourceOnly:0)
  precondition(source.items.count==1 && source.items[0].id==0)
  print("PASS: \(checks) combinations of layout/featured slot/landscape/portrait/narrow windows; visible counts, unique stable IDs, bounds, non-overlap, lower-row geometry, Solo/restoration and source-only override.")
 }
}
