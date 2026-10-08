// Клавиатура на экране «Диктовка»: трёхмерная модель, повёрнутая так,
// чтобы были видны клавиши, и выбранная клавиша сама время от времени
// нажимается — это понятнее любой подписи «правый ⌘».

import AppKit
import SceneKit
import SwiftUI

enum KeyboardModel {
    /// Какой узел модели отвечает за какую клавишу из наших настроек.
    /// У правого ⌃ пары нет: на клавиатуре Apple такой клавиши просто
    /// не существует, она бывает только на сторонних, — и подсвечивать
    /// вместо неё левую было бы обманом.
    static func node(for hotkeyId: String) -> String? {
        switch hotkeyId {
        case "rcmd": return "key_command_right"
        case "ropt": return "key_option_right"
        case "fn":   return "Keycap___Globe"
        default:     return nil
        }
    }

    /// Оттенок выбранной клавиши. Умножением, а не заливкой: так на ней
    /// остаются блики и грани, клавиша просто становится голубоватой.
    static let tint = NSColor(srgbRed: 1.0, green: 0.82, blue: 0.62, alpha: 1)

    /// Цвет карточки, на которой стоит сцена. Прозрачной SceneKit её не
    /// отдаёт — рисует свой белый холст поверх серой карточки, — поэтому
    /// красим холст в тот же цвет, что и карточка (`Color.cardFill` —
    /// 5% основного поверх фона колонки), и следим за темой.
    static func backdrop(for appearance: NSAppearance) -> NSColor {
        var color = NSColor.textBackgroundColor
        appearance.performAsCurrentDrawingAppearance {
            color = NSColor.textBackgroundColor.blended(withFraction: 0.05, of: .labelColor)
                ?? NSColor.textBackgroundColor
        }
        return color
    }

    /// Насколько клавиша уходит вниз при нажатии (модель в метрах,
    /// толщина корпуса — 11 мм).
    static let travel: CGFloat = 0.0016
}

struct KeyboardView: NSViewRepresentable {
    /// Какую клавишу нажимать: id из HOTKEYS.
    let hotkeyId: String
    /// Докуда камера отъезжает к краю корпуса. Больше значение — больше
    /// просвет между клавиатурой и краем кадра. 0.0635 оставляет 16 pt
    /// при ширине 459 (настройки), 0.069 — 32 pt при 648 (первый запуск).
    var edge: CGFloat = 0.0635
    /// Насколько отодвинуть камеру. Единица — как в настройках; больше —
    /// клавиатура в кадре мельче и занимает меньше высоты.
    var pullback: CGFloat = 1
    /// Чем закрасить холст сцены. Прозрачной SceneKit её не отдаёт,
    /// поэтому красим в цвет того, на чём она лежит.
    var backdrop: NSColor? = nil

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = backdrop ?? KeyboardModel.backdrop(for: view.effectiveAppearance)
        view.antialiasingMode = .multisampling4X
        // Без этого клавиша не нажимается: SCNView не крутит анимации,
        // пока его не попросят.
        view.isPlaying = true
        view.allowsCameraControl = false
        view.scene = context.coordinator.makeScene()
        context.coordinator.view = view
        context.coordinator.setFrame(edge: edge, pullback: pullback)
        context.coordinator.start(hotkeyId)
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        // Тема могла смениться, пока окно открыто.
        view.backgroundColor = backdrop ?? KeyboardModel.backdrop(for: view.effectiveAppearance)
        context.coordinator.setFrame(edge: edge, pullback: pullback)
        context.coordinator.start(hotkeyId)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var view: SCNView?
        private var scene: SCNScene?
        private var cameraNode: SCNNode?
        private var timer: Timer?
        private var chosen: String?
        /// Докуда камера отъезжает к краю корпуса и насколько она отодвинута.
        private var edge: CGFloat = 0.0635
        private var pullback: CGFloat = 1

        /// Кадр задаётся снаружи и может смениться на лету: тогда камеру
        /// надо навести заново, сама она об этом не узнает.
        func setFrame(edge: CGFloat, pullback: CGFloat) {
            guard edge != self.edge || pullback != self.pullback else { return }
            self.edge = edge
            self.pullback = pullback
            // Навести заново: камера сама о новом кадре не узнает.
            let id = chosen
            chosen = nil
            if let id { start(id) }
        }
        private var tinted: SCNNode?
        /// Нажатая сейчас клавиша: если выбрать другую, пока эта внизу,
        /// её надо отпустить сразу, а не ждать, пока доиграет своё.
        private var pressed: SCNNode?
        /// Положение каждой клавиши в покое, запомненное до первого
        /// нажатия: анимации ходят к нему, а не сдвигают от текущего, —
        /// иначе прерванное нажатие оставляет клавишу чуть утопленной.
        private var rest: [ObjectIdentifier: SCNVector3] = [:]

        var camera: SCNNode? { cameraNode }

        func makeScene() -> SCNScene? {
            guard let url = Bundle.main.url(forResource: "keyboard", withExtension: "usdz"),
                  let scene = try? SCNScene(url: url) else { return nil }

            // Камера смотрит сверху-спереди: под таким углом видно и клавиши,
            // и то, что это клавиатура.
            let camera = SCNCamera()
            camera.fieldOfView = 46
            // Угол считаем по ширине: карточка широкая и низкая, иначе
            // клавиатура болтается посередине крошечной.
            camera.projectionDirection = .horizontal
            // Модель размером с настоящую клавиатуру — 28 см, а ближняя
            // плоскость у SceneKit по умолчанию в метре: без этого сцена
            // просто пустая.
            camera.zNear = 0.01
            camera.zFar = 10
            let cameraNode = SCNNode()
            cameraNode.camera = camera
            scene.rootNode.addChildNode(cameraNode)
            self.cameraNode = cameraNode

            let key = SCNNode()
            key.light = SCNLight()
            key.light?.type = .directional
            key.light?.intensity = 650
            key.eulerAngles = SCNVector3(-0.9, 0.4, 0)
            scene.rootNode.addChildNode(key)

            let fill = SCNNode()
            fill.light = SCNLight()
            fill.light?.type = .ambient
            fill.light?.intensity = 330
            scene.rootNode.addChildNode(fill)

            self.scene = scene
            return scene
        }

        /// Камера всегда смотрит одинаково, вперёд и чуть вниз, — к нужной
        /// клавише она едет вбок. Поворачивать её значило бы показывать
        /// клавиатуру каждый раз под новым углом.
        private func aim(at key: SCNNode, animated: Bool) {
            guard let cameraNode else { return }
            SCNTransaction.begin()
            SCNTransaction.animationDuration = animated ? 0.5 : 0
            cameraNode.eulerAngles = SCNVector3(-0.2545, 0, 0)
            // Клавиша всегда с краю: если она справа — показываем правый
            // край корпуса, если слева — левый, и в обоих случаях между
            // ним и краем карточки остаются те же 16 pt, что у строк.
            let side: CGFloat = key.worldPosition.x > 0 ? edge : -edge
            // Отодвигаем по оси взгляда: наклон тот же, клавиатура мельче.
            cameraNode.position = SCNVector3(side, 0.062 * pullback, 0.235 * pullback)
            SCNTransaction.commit()
        }

        /// Нажатие держится три секунды: так успеваешь заметить, какая
        /// клавиша утонула, и это не мельтешит.
        func start(_ hotkeyId: String) {
            guard hotkeyId != chosen else { return }
            let first = chosen == nil
            chosen = hotkeyId
            release()
            timer?.invalidate()
            // Белый вместо nil: сброс contents в nil материал не всегда
            // подхватывает, а умножение на белое ничего не меняет.
            paint(tinted, .white)
            tinted = nil

            // Клавиши в модели нет — камера остаётся там же, где была,
            // просто ничего не подсвечено и не нажимается.
            guard let name = KeyboardModel.node(for: hotkeyId),
                  let key = scene?.rootNode.childNode(withName: name, recursively: true) else { return }

            aim(at: key, animated: !first)
            paint(key, KeyboardModel.tint)
            tinted = key
            timer = Timer.scheduledTimer(withTimeInterval: 5.5, repeats: true) { [weak self] _ in
                self?.press(name)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.press(name) }
        }

        /// Материалы у клавиш свои, не общие, так что красим прямо их.
        private func paint(_ node: SCNNode?, _ color: NSColor) {
            node?.enumerateHierarchy { child, _ in
                child.geometry?.materials.forEach { $0.multiply.contents = color }
            }
        }

        /// Вернуть нажатую клавишу на место, не дожидаясь конца паузы, —
        /// но так же плавно, как она возвращается сама.
        private func release() {
            guard let node = pressed else { return }
            pressed = nil
            node.removeAllActions()
            guard let home = rest[ObjectIdentifier(node)] else { return }
            let up = SCNAction.move(to: home, duration: 0.22)
            up.timingMode = .easeInEaseOut
            node.runAction(up)
        }

        private func press(_ name: String) {
            guard let node = scene?.rootNode.childNode(withName: name, recursively: true) else { return }
            release()
            let id = ObjectIdentifier(node)
            let home = rest[id] ?? node.position
            rest[id] = home
            pressed = node
            // Внутри модели клавиатура лежит в своей системе координат,
            // где вверх — это Z: по Y клавиша уезжала вдоль корпуса,
            // а не в него.
            let sunk = SCNVector3(home.x, home.y, home.z - KeyboardModel.travel)
            let down = SCNAction.move(to: sunk, duration: 0.1)
            let up = SCNAction.move(to: home, duration: 0.22)
            down.timingMode = .easeOut
            up.timingMode = .easeInEaseOut
            node.removeAllActions()
            node.runAction(.sequence([down, .wait(duration: 3.0), up])) { [weak self] in
                // Конец анимации приходит не с главного потока, и к этому
                // моменту нажатой может быть уже другая клавиша.
                DispatchQueue.main.async {
                    if self?.pressed === node { self?.pressed = nil }
                }
            }
        }

        deinit { timer?.invalidate() }
    }
}
