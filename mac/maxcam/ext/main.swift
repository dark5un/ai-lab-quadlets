// main.swift — Camera Extension entry (exact template shape)
import Foundation
import CoreMediaIO

let providerSource = MaxCamProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)

CFRunLoopRun()
