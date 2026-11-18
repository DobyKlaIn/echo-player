import UIKit
import CoreImage

/// Кэш обложек: большие для экрана плеера, маленькие для списков
final class ArtworkCache {
    static let shared = ArtworkCache()

    private let cache = NSCache<NSString, UIImage>()
    private var missing = Set<String>()
    private let lock = NSLock()

    init() {
        cache.countLimit = 400
    }

    func image(for id: String) -> UIImage? {
        load(key: id, file: "\(id).jpg")
    }

    func thumb(for id: String) -> UIImage? {
        load(key: "\(id)_s", file: "\(id)_s.jpg") ?? image(for: id)
    }

    func invalidate(_ id: String) {
        lock.lock()
        missing.remove(id)
        missing.remove("\(id)_s")
        lock.unlock()
        cache.removeObject(forKey: id as NSString)
        cache.removeObject(forKey: "\(id)_s" as NSString)
    }

    private func load(key: String, file: String) -> UIImage? {
        if let img = cache.object(forKey: key as NSString) { return img }
        lock.lock()
        let isMissing = missing.contains(key)
        lock.unlock()
        if isMissing { return nil }
        let url = Library.artworkDir.appendingPathComponent(file)
        guard let img = UIImage(contentsOfFile: url.path) else {
            lock.lock()
            missing.insert(key)
            lock.unlock()
            return nil
        }
        cache.setObject(img, forKey: key as NSString)
        return img
    }
}

enum ColorTools {
    private static let context = CIContext(options: [.workingColorSpace: NSNull()])

    /// Средний цвет обложки — для фона экрана плеера
    static func averageColor(of image: UIImage) -> UIColor? {
        guard let input = CIImage(image: image) else { return nil }
        let extent = CIVector(x: input.extent.origin.x, y: input.extent.origin.y,
                              z: input.extent.size.width, w: input.extent.size.height)
        guard let filter = CIFilter(name: "CIAreaAverage",
                                    parameters: [kCIInputImageKey: input, kCIInputExtentKey: extent]),
              let output = filter.outputImage else { return nil }
        var bitmap = [UInt8](repeating: 0, count: 4)
        context.render(output, toBitmap: &bitmap, rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: nil)
        let base = UIColor(red: CGFloat(bitmap[0]) / 255, green: CGFloat(bitmap[1]) / 255,
                           blue: CGFloat(bitmap[2]) / 255, alpha: 1)
        return tuned(base)
    }

    /// Делаем цвет насыщеннее и не слишком тёмным/светлым
    static func tuned(_ color: UIColor) -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard color.getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return color }
        let newS = min(1, max(0.25, s * 1.3))
        let newB = min(0.72, max(0.38, b))
        return UIColor(hue: h, saturation: newS, brightness: newB, alpha: 1)
    }

    /// Цвет-заглушка по id трека
    static func seedColors(_ seed: String) -> (UIColor, UIColor) {
        let h = stableHash(seed)
        let hue1 = CGFloat(h % 360) / 360
        let hue2 = CGFloat((h / 360) % 360) / 360
        return (UIColor(hue: hue1, saturation: 0.55, brightness: 0.55, alpha: 1),
                UIColor(hue: hue2, saturation: 0.65, brightness: 0.35, alpha: 1))
    }
}
