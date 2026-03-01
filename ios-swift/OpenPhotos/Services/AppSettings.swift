import Foundation
import UIKit

enum AppSettings {
    static var url: URL? { URL(string: UIApplication.openSettingsURLString) }
}

