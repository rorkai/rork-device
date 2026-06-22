import XCTest

@testable import RorkDeviceWeb

final class WebUSBInterfaceSelectionTests: XCTestCase {
    func testSelectsAppleDirectMuxInterfaceWithBulkEndpoints() throws {
        let selection = try XCTUnwrap(
            selectDirectUSBMuxInterface(
                from: [
                    USBConfigurationDescriptor(
                        value: 1,
                        interfaces: [
                            USBInterfaceDescriptor(
                                number: 3,
                                alternates: [
                                    USBAlternateDescriptor(
                                        setting: 0,
                                        classCode: 255,
                                        subclassCode: 254,
                                        protocolCode: 2,
                                        endpoints: [
                                            USBEndpointDescriptor(
                                                number: 1,
                                                direction: .output,
                                                transferType: .bulk,
                                                maximumPacketSize: 512
                                            ),
                                            USBEndpointDescriptor(
                                                number: 2,
                                                direction: .input,
                                                transferType: .bulk,
                                                maximumPacketSize: 512
                                            ),
                                        ]
                                    )
                                ]
                            )
                        ]
                    )
                ]
            )
        )

        XCTAssertEqual(
            selection,
            DirectUSBMuxInterfaceSelection(
                configurationValue: 1,
                interfaceNumber: 3,
                alternateSetting: 0,
                inputEndpoint: 2,
                outputEndpoint: 1,
                outputMaximumPacketSize: 512
            )
        )
    }

    func testSkipsMatchingAlternateWithoutBothBulkDirections() {
        let selection = selectDirectUSBMuxInterface(
            from: [
                USBConfigurationDescriptor(
                    value: 1,
                    interfaces: [
                        USBInterfaceDescriptor(
                            number: 3,
                            alternates: [
                                USBAlternateDescriptor(
                                    setting: 0,
                                    classCode: 255,
                                    subclassCode: 254,
                                    protocolCode: 2,
                                    endpoints: [
                                        USBEndpointDescriptor(
                                            number: 1,
                                            direction: .input,
                                            transferType: .interrupt,
                                            maximumPacketSize: 64
                                        ),
                                        USBEndpointDescriptor(
                                            number: 2,
                                            direction: .output,
                                            transferType: .bulk,
                                            maximumPacketSize: 512
                                        ),
                                    ]
                                )
                            ]
                        )
                    ]
                )
            ]
        )

        XCTAssertNil(selection)
    }

    func testIgnoresUnrelatedVendorInterfaces() {
        let selection = selectDirectUSBMuxInterface(
            from: [
                USBConfigurationDescriptor(
                    value: 1,
                    interfaces: [
                        USBInterfaceDescriptor(
                            number: 3,
                            alternates: [
                                USBAlternateDescriptor(
                                    setting: 0,
                                    classCode: 255,
                                    subclassCode: 1,
                                    protocolCode: 1,
                                    endpoints: [
                                        USBEndpointDescriptor(
                                            number: 1,
                                            direction: .output,
                                            transferType: .bulk,
                                            maximumPacketSize: 512
                                        ),
                                        USBEndpointDescriptor(
                                            number: 2,
                                            direction: .input,
                                            transferType: .bulk,
                                            maximumPacketSize: 512
                                        ),
                                    ]
                                )
                            ]
                        )
                    ]
                )
            ]
        )

        XCTAssertNil(selection)
    }
}
