/// Browser-reported USB configuration relevant to interface selection.
struct USBConfigurationDescriptor: Equatable, Sendable {
    /// Value passed to WebUSB when selecting this configuration.
    let value: UInt8

    /// Interfaces exposed by the configuration.
    let interfaces: [USBInterfaceDescriptor]
}

/// Browser-reported USB interface and its alternate settings.
struct USBInterfaceDescriptor: Equatable, Sendable {
    /// Interface number passed to WebUSB claim and alternate-selection calls.
    let number: UInt8

    /// Alternate descriptors advertised for the interface.
    let alternates: [USBAlternateDescriptor]
}

/// One alternate USB interface descriptor.
struct USBAlternateDescriptor: Equatable, Sendable {
    /// Alternate setting passed to WebUSB after claiming the interface.
    let setting: UInt8

    /// USB interface class code.
    let classCode: UInt8

    /// USB interface subclass code.
    let subclassCode: UInt8

    /// USB interface protocol code.
    let protocolCode: UInt8

    /// Endpoints available while this alternate is selected.
    let endpoints: [USBEndpointDescriptor]
}

/// Browser-reported USB endpoint descriptor.
struct USBEndpointDescriptor: Equatable, Sendable {
    /// Endpoint number used by WebUSB transfers.
    let number: UInt8

    /// Direction relative to the browser host.
    let direction: USBEndpointDirection

    /// Transfer semantics declared by the endpoint.
    let transferType: USBTransferType

    /// Largest USB packet accepted by the endpoint.
    let maximumPacketSize: Int
}

/// Direction of a USB endpoint relative to the host.
enum USBEndpointDirection: Equatable, Sendable {
    /// Device-to-host endpoint.
    case input

    /// Host-to-device endpoint.
    case output
}

/// Transfer semantics relevant to direct usbmux.
enum USBTransferType: Equatable, Sendable {
    /// Bulk endpoint used for reliable usbmux packets.
    case bulk

    /// Interrupt endpoint, which cannot carry the direct usbmux stream.
    case interrupt

    /// Isochronous endpoint, which cannot provide reliable usbmux delivery.
    case isochronous

    /// Control endpoint represented in a browser descriptor.
    case control
}

/// Complete WebUSB route to Apple's direct usbmux interface.
struct DirectUSBMuxInterfaceSelection: Equatable, Sendable {
    /// Configuration containing the selected interface.
    let configurationValue: UInt8

    /// Interface claimed for direct usbmux transfers.
    let interfaceNumber: UInt8

    /// Alternate setting containing both bulk endpoints.
    let alternateSetting: UInt8

    /// Device-to-host bulk endpoint.
    let inputEndpoint: UInt8

    /// Host-to-device bulk endpoint.
    let outputEndpoint: UInt8

    /// Largest packet accepted by the host-to-device bulk endpoint.
    let outputMaximumPacketSize: Int
}

/// Selects the first complete Apple direct-usbmux interface.
///
/// Apple identifies this interface with class `255`, subclass `254`, and
/// protocol `2`. A usable alternate must also expose one bulk endpoint in each
/// direction; matching the class tuple alone is insufficient because composite
/// devices can publish incomplete or unrelated alternates.
func selectDirectUSBMuxInterface(
    from configurations: [USBConfigurationDescriptor]
) -> DirectUSBMuxInterfaceSelection? {
    for configuration in configurations {
        for interface in configuration.interfaces {
            for alternate in interface.alternates
            where alternate.classCode == 255
                && alternate.subclassCode == 254
                && alternate.protocolCode == 2
            {
                let inputEndpoint = alternate.endpoints.first {
                    $0.direction == .input && $0.transferType == .bulk
                }
                let outputEndpoint = alternate.endpoints.first {
                    $0.direction == .output && $0.transferType == .bulk
                }
                guard let inputEndpoint, let outputEndpoint else {
                    continue
                }

                return DirectUSBMuxInterfaceSelection(
                    configurationValue: configuration.value,
                    interfaceNumber: interface.number,
                    alternateSetting: alternate.setting,
                    inputEndpoint: inputEndpoint.number,
                    outputEndpoint: outputEndpoint.number,
                    outputMaximumPacketSize:
                        outputEndpoint.maximumPacketSize
                )
            }
        }
    }
    return nil
}
