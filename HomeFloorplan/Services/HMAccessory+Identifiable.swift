import HomeKit

extension HMAccessory: @retroactive Identifiable {
    public var id: UUID { uniqueIdentifier }
}

extension HMRoom: @retroactive Identifiable {
    public var id: UUID { uniqueIdentifier }
}
