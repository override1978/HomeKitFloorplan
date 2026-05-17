//
//  Item.swift
//  HomeFloorplan
//
//  Created by Maurizio Cinti on 17/05/26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
