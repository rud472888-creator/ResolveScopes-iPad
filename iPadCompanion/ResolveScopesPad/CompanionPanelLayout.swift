import Foundation
import CoreGraphics

enum CompanionLayoutStyle:String,CaseIterable,Identifiable {
    case grid,largeWithTwo,largeWithThree,largeWithFour
    var id:String {rawValue}
    var title:String {
        switch self {
        case .grid:return "균등 그리드"
        case .largeWithTwo:return "큰 패널 + 아래 2개"
        case .largeWithThree:return "큰 패널 + 아래 3개"
        case .largeWithFour:return "큰 패널 + 아래 4개"
        }
    }
    var smallCount:Int? {
        switch self {case .grid:return nil;case .largeWithTwo:return 2;case .largeWithThree:return 3;case .largeWithFour:return 4}
    }
}

/// Stable slot IDs retain each panel's local zoom and GPU registration when it
/// moves between the featured area and the lower row. Only visibility changes
/// add/remove views. Geometry uses the actual available panel area, not screen size.
struct CompanionPanelLayout {
    struct Item:Identifiable {
        let id:Int
        let frame:CGRect
    }
    let items:[Item]
    let contentHeight:CGFloat
    static func make(size:CGSize,panelCount:Int,style:CompanionLayoutStyle,columns:Int,featured:Int,solo:Int?=nil,sourceOnly:Int?=nil)->Self {
        let gap:CGFloat=8,inset:CGFloat=8
        let width=max(1,size.width.isFinite ? size.width:1),height=max(1,size.height.isFinite ? size.height:1)
        let available=max(1,width-2*inset)
        guard panelCount>0 else {return Self(items:[],contentHeight:height)}
        if let selected=sourceOnly ?? solo,(0..<panelCount).contains(selected) {
            return Self(items:[Item(id:selected,frame:CGRect(x:inset,y:inset,width:available,height:max(190,height-2*inset)))],contentHeight:max(height,210))
        }
        if let requested=style.smallCount,panelCount>1 {
            let main=min(panelCount-1,max(0,featured))
            let lower=Array((0..<panelCount).filter{$0 != main}.prefix(requested))
            // A narrow Stage Manager window wraps the lower row instead of
            // squeezing four complete panel headers into unreadable slivers.
            let lowerColumns=max(1,min(lower.count,Int((available+gap)/(220+gap))))
            let rows=(lower.count+lowerColumns-1)/lowerColumns
            let usable=max(1,height-2*inset-gap)
            let ratio:CGFloat=width>=height ? 0.70:0.64
            let largeHeight=max(220,usable*ratio)
            let lowerHeight=max(150,(usable-largeHeight-CGFloat(rows-1)*gap)/CGFloat(rows))
            let smallWidth=max(1,(available-CGFloat(lowerColumns-1)*gap)/CGFloat(lowerColumns))
            var items=[Item(id:main,frame:CGRect(x:inset,y:inset,width:available,height:largeHeight))]
            for (position,index) in lower.enumerated() {
                items.append(Item(id:index,frame:CGRect(x:inset+CGFloat(position%lowerColumns)*(smallWidth+gap),y:inset+largeHeight+gap+CGFloat(position/lowerColumns)*(lowerHeight+gap),width:smallWidth,height:lowerHeight)))
            }
            return Self(items:items,contentHeight:inset+largeHeight+gap+CGFloat(rows)*lowerHeight+CGFloat(rows-1)*gap+inset)
        }
        let count=max(1,min(3,columns)),rows=(panelCount+count-1)/count
        let cellWidth=max(1,(available-CGFloat(count-1)*gap)/CGFloat(count))
        let cellHeight=max(190,(height-2*inset-CGFloat(rows-1)*gap)/CGFloat(rows))
        return Self(items:(0..<panelCount).map{index in
            Item(id:index,frame:CGRect(x:inset+CGFloat(index%count)*(cellWidth+gap),y:inset+CGFloat(index/count)*(cellHeight+gap),width:cellWidth,height:cellHeight))
        },contentHeight:2*inset+CGFloat(rows)*cellHeight+CGFloat(rows-1)*gap)
    }
}
