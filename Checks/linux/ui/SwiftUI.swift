// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
// A stand-in for the part of SwiftUI that the onboarding screens and the baby figure use, so that they
// can be TYPE-CHECKED on Linux (argument labels, types, generics, builders). Signatures follow the iOS 17
// SDK. Nothing here draws anything, and an Xcode build is still required.
@_exported import Foundation

// MARK: CoreGraphics types Foundation lacks on Linux
public struct CGVector: Equatable, Sendable {
    public var dx: CGFloat, dy: CGFloat
    public init(dx: CGFloat, dy: CGFloat) { self.dx = dx; self.dy = dy }
    public static let zero = CGVector(dx: 0, dy: 0)
}
public struct CGAffineTransform: Equatable, Sendable {
    public var a: CGFloat, b: CGFloat, c: CGFloat, d: CGFloat, tx: CGFloat, ty: CGFloat
    public init(a: CGFloat, b: CGFloat, c: CGFloat, d: CGFloat, tx: CGFloat, ty: CGFloat) { self.a = a; self.b = b; self.c = c; self.d = d; self.tx = tx; self.ty = ty }
    public init(translationX: CGFloat, y: CGFloat) { self.init(a: 1, b: 0, c: 0, d: 1, tx: translationX, ty: y) }
    public init(scaleX: CGFloat, y: CGFloat) { self.init(a: scaleX, b: 0, c: 0, d: y, tx: 0, ty: 0) }
    public init(rotationAngle: CGFloat) { self.init(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0) }
    public static let identity = CGAffineTransform(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)
    public func rotated(by angle: CGFloat) -> CGAffineTransform { self }
    public func scaledBy(x: CGFloat, y: CGFloat) -> CGAffineTransform { self }
    public func translatedBy(x: CGFloat, y: CGFloat) -> CGAffineTransform { self }
    public func inverted() -> CGAffineTransform { self }
    public func concatenating(_ t: CGAffineTransform) -> CGAffineTransform { self }
}
extension CGPoint { public func applying(_ t: CGAffineTransform) -> CGPoint { self } }

// MARK: UIKit bits reachable through SwiftUI
public final class UIColor: @unchecked Sendable {
    public init() {}
    public static let secondarySystemBackground = UIColor()
}

// MARK: View and its builder
public protocol View {
    associatedtype Body: View
    @ViewBuilder var body: Body { get }
}
extension Never: View { public var body: Never { fatalError() } }
public protocol _Leaf: View where Body == Never {}
extension _Leaf { public var body: Never { fatalError() } }
public struct EmptyView: _Leaf { public init() {} }
public struct TupleView<T>: _Leaf {}
public struct _ConditionalContent<T: View, F: View>: _Leaf {}
public struct _Modified<Content: View>: _Leaf {}
extension Optional: View where Wrapped: View { public var body: Never { fatalError() } }

@resultBuilder public enum ViewBuilder {
    public static func buildExpression<C: View>(_ c: C) -> C { c }
    public static func buildBlock() -> EmptyView { EmptyView() }
    public static func buildBlock<C: View>(_ c: C) -> C { c }
    public static func buildBlock<each C: View>(_ c: repeat each C) -> TupleView<(repeat each C)> { fatalError() }
    public static func buildIf<C: View>(_ c: C?) -> C? { c }
    public static func buildEither<T: View, F: View>(first: T) -> _ConditionalContent<T, F> { fatalError() }
    public static func buildEither<T: View, F: View>(second: F) -> _ConditionalContent<T, F> { fatalError() }
    public static func buildLimitedAvailability<C: View>(_ c: C) -> C { c }
}

// MARK: values
public struct Angle: Equatable, Sendable {
    public var radians: Double
    public static func degrees(_ d: Double) -> Angle { Angle(radians: d * .pi / 180) }
    public static func radians(_ r: Double) -> Angle { Angle(radians: r) }
    public init(radians: Double) { self.radians = radians }
}
public enum Edge: Sendable {
    case top, leading, bottom, trailing
    public struct Set: OptionSet, Sendable {
        public let rawValue: Int8
        public init(rawValue: Int8) { self.rawValue = rawValue }
        public static let top = Set(rawValue: 1), leading = Set(rawValue: 2), bottom = Set(rawValue: 4), trailing = Set(rawValue: 8)
        public static let horizontal: Set = [.leading, .trailing], vertical: Set = [.top, .bottom], all: Set = [.horizontal, .vertical]
    }
}
public enum VerticalEdge: Sendable { case top, bottom }
public enum Axis: Sendable {
    case horizontal, vertical
    public struct Set: OptionSet, Sendable {
        public let rawValue: Int8
        public init(rawValue: Int8) { self.rawValue = rawValue }
        public static let horizontal = Set(rawValue: 1), vertical = Set(rawValue: 2)
    }
}
public struct HorizontalAlignment: Sendable { public static let leading = HorizontalAlignment(), center = HorizontalAlignment(), trailing = HorizontalAlignment() }
public struct VerticalAlignment: Sendable { public static let top = VerticalAlignment(), center = VerticalAlignment(), bottom = VerticalAlignment(), firstTextBaseline = VerticalAlignment() }
public struct Alignment: Sendable {
    public static let center = Alignment(), leading = Alignment(), trailing = Alignment(), top = Alignment(), bottom = Alignment()
    public static let topLeading = Alignment(), topTrailing = Alignment(), bottomLeading = Alignment(), bottomTrailing = Alignment()
}
public enum TextAlignment: Sendable { case leading, center, trailing }
public enum RoundedCornerStyle: Sendable { case circular, continuous }
public enum CGLineCap: Sendable { case butt, round, square }
public enum CGLineJoin: Sendable { case miter, round, bevel }
public struct StrokeStyle: Equatable, Sendable {
    public init(lineWidth: CGFloat = 1, lineCap: CGLineCap = .butt, lineJoin: CGLineJoin = .miter, miterLimit: CGFloat = 10, dash: [CGFloat] = [], dashPhase: CGFloat = 0) {}
}
public struct FillStyle: Equatable, Sendable { public init(eoFill: Bool = false, antialiased: Bool = true) {} }

// MARK: styles
public protocol ShapeStyle {}
public struct Color: ShapeStyle, _Leaf, Hashable, Sendable {
    public init(_ uiColor: UIColor) {}
    public init(red: Double, green: Double, blue: Double, opacity: Double = 1) {}
    public func opacity(_ opacity: Double) -> Color { self }
    public static let red = Color(UIColor()), green = Color(UIColor()), white = Color(UIColor()), black = Color(UIColor())
    public static let clear = Color(UIColor()), primary = Color(UIColor()), secondary = Color(UIColor()), orange = Color(UIColor())
    public func ignoresSafeArea(_ regions: Int = 0, edges: Edge.Set = .all) -> some View { self }
    public static func == (a: Color, b: Color) -> Bool { true }
    public func hash(into hasher: inout Hasher) {}
}
extension ShapeStyle where Self == Color {
    public static var red: Color { .red }
    public static var green: Color { .green }
    public static var white: Color { .white }
    public static var black: Color { .black }
    public static var clear: Color { .clear }
    public static var orange: Color { .orange }
}
public struct HierarchicalShapeStyle: ShapeStyle, Sendable {}
extension ShapeStyle where Self == HierarchicalShapeStyle {
    public static var primary: HierarchicalShapeStyle { HierarchicalShapeStyle() }
    public static var secondary: HierarchicalShapeStyle { HierarchicalShapeStyle() }
}
public struct Material: ShapeStyle, Sendable {}
extension ShapeStyle where Self == Material {
    public static var regularMaterial: Material { Material() }
    public static var ultraThinMaterial: Material { Material() }
    public static var bar: Material { Material() }
}
public struct Gradient: Equatable, Sendable {
    public struct Stop: Equatable, Sendable { public init(color: Color, location: CGFloat) {} }
    public init(colors: [Color]) {}
    public init(stops: [Stop]) {}
}
public struct Font: Hashable, Sendable {
    public enum TextStyle: Sendable { case largeTitle, title, title2, title3, headline, subheadline, body, callout, footnote, caption, caption2 }
    public enum Design: Sendable { case `default`, serif, rounded, monospaced }
    public struct Weight: Hashable, Sendable { public static let regular = Weight(), medium = Weight(), semibold = Weight(), bold = Weight() }
    public static let largeTitle = Font(), title = Font(), title2 = Font(), title3 = Font(), headline = Font(), subheadline = Font()
    public static let body = Font(), callout = Font(), footnote = Font(), caption = Font(), caption2 = Font()
    public static func system(_ style: TextStyle, design: Design? = nil, weight: Weight? = nil) -> Font { Font() }
    public static func system(size: CGFloat, weight: Weight? = nil, design: Design? = nil) -> Font { Font() }
    public func weight(_ weight: Weight) -> Font { self }
    public func monospacedDigit() -> Font { self }
    public func monospaced() -> Font { self }
}

// MARK: shapes and paths
public protocol Shape: View { func path(in rect: CGRect) -> Path }
public protocol InsettableShape: Shape {}
extension Shape {
    public var body: Never { fatalError() }
    public func fill<S: ShapeStyle>(_ content: S, style: FillStyle = FillStyle()) -> some View { EmptyView() }
    public func stroke<S: ShapeStyle>(_ content: S, lineWidth: CGFloat = 1) -> some View { EmptyView() }
    public func stroke<S: ShapeStyle>(_ content: S, style: StrokeStyle) -> some View { EmptyView() }
}
extension InsettableShape {
    public func strokeBorder<S: ShapeStyle>(_ content: S, style: StrokeStyle, antialiased: Bool = true) -> some View { EmptyView() }
    public func strokeBorder<S: ShapeStyle>(_ content: S, lineWidth: CGFloat = 1, antialiased: Bool = true) -> some View { EmptyView() }
}
public struct Rectangle: InsettableShape { public init() {}; public func path(in rect: CGRect) -> Path { Path() } }
public struct Circle: InsettableShape { public init() {}; public func path(in rect: CGRect) -> Path { Path() } }
public struct Capsule: InsettableShape { public init(style: RoundedCornerStyle = .circular) {}; public func path(in rect: CGRect) -> Path { Path() } }
public struct RoundedRectangle: InsettableShape {
    public init(cornerRadius: CGFloat, style: RoundedCornerStyle = .circular) {}
    public func path(in rect: CGRect) -> Path { Path() }
}
public struct Path: Shape, Equatable, Sendable {
    public init() {}
    public init(_ rect: CGRect) {}
    public init(ellipseIn rect: CGRect) {}
    public init(roundedRect rect: CGRect, cornerRadius: CGFloat, style: RoundedCornerStyle = .circular) {}
    public func path(in rect: CGRect) -> Path { self }
    public var isEmpty: Bool { true }
    public var boundingRect: CGRect { .zero }
    public mutating func move(to p: CGPoint) {}
    public mutating func addLine(to p: CGPoint) {}
    public mutating func addLines(_ lines: [CGPoint]) {}
    public mutating func addCurve(to p: CGPoint, control1: CGPoint, control2: CGPoint) {}
    public mutating func addQuadCurve(to p: CGPoint, control: CGPoint) {}
    public mutating func addArc(center: CGPoint, radius: CGFloat, startAngle: Angle, endAngle: Angle, clockwise: Bool, transform: CGAffineTransform = .identity) {}
    public mutating func addEllipse(in rect: CGRect, transform: CGAffineTransform = .identity) {}
    public mutating func addRect(_ rect: CGRect, transform: CGAffineTransform = .identity) {}
    public mutating func addPath(_ path: Path, transform: CGAffineTransform = .identity) {}
    public mutating func closeSubpath() {}
    public func applying(_ transform: CGAffineTransform) -> Path { self }
    public func strokedPath(_ style: StrokeStyle) -> Path { self }
    public func union(_ other: Path, eoFill: Bool = false) -> Path { self }
    public func intersection(_ other: Path, eoFill: Bool = false) -> Path { self }
    public func contains(_ p: CGPoint, eoFill: Bool = false) -> Bool { false }
}

// MARK: Canvas
public struct GraphicsContext {
    public struct Shading {
        public static func color(_ color: Color) -> Shading { Shading() }
        public static func linearGradient(_ gradient: Gradient, startPoint: CGPoint, endPoint: CGPoint) -> Shading { Shading() }
        public static func radialGradient(_ gradient: Gradient, center: CGPoint, startRadius: CGFloat, endRadius: CGFloat) -> Shading { Shading() }
    }
    public struct Filter { public static func blur(radius: CGFloat) -> Filter { Filter() } }
    public var opacity: Double = 1
    public var transform: CGAffineTransform = .identity
    public func fill(_ path: Path, with shading: Shading, style: FillStyle = FillStyle()) {}
    public func stroke(_ path: Path, with shading: Shading, style: StrokeStyle) {}
    public func stroke(_ path: Path, with shading: Shading, lineWidth: CGFloat = 1) {}
    public func draw(_ text: Text, at point: CGPoint) {}
    public mutating func clip(to path: Path, style: FillStyle = FillStyle()) {}
    public mutating func concatenate(_ matrix: CGAffineTransform) {}
    public mutating func translateBy(x: CGFloat, y: CGFloat) {}
    public mutating func scaleBy(x: CGFloat, y: CGFloat) {}
    public mutating func rotate(by angle: Angle) {}
    public mutating func addFilter(_ filter: Filter) {}
    public func drawLayer(content: (inout GraphicsContext) throws -> Void) rethrows {}
}
public struct Canvas<Symbols: View>: _Leaf {
    public init(opaque: Bool = false, rendersAsynchronously: Bool = false, renderer: @escaping (inout GraphicsContext, CGSize) -> Void) where Symbols == EmptyView {}
}

// MARK: containers
public struct VStack<Content: View>: _Leaf { public init(alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {} }
public struct HStack<Content: View>: _Leaf { public init(alignment: VerticalAlignment = .center, spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {} }
public struct ZStack<Content: View>: _Leaf { public init(alignment: Alignment = .center, @ViewBuilder content: () -> Content) {} }
public struct Group<Content: View>: _Leaf { public init(@ViewBuilder content: () -> Content) {} }
public struct Spacer: _Leaf { public init(minLength: CGFloat? = nil) {} }
public struct ScrollView<Content: View>: _Leaf { public init(_ axes: Axis.Set = .vertical, showsIndicators: Bool = true, @ViewBuilder content: () -> Content) {} }
public struct GeometryProxy { public var size: CGSize { .zero } }
public struct GeometryReader<Content: View>: _Leaf { public init(@ViewBuilder content: @escaping (GeometryProxy) -> Content) {} }
public struct ViewThatFits<Content: View>: _Leaf { public init(in axes: Axis.Set = [.horizontal, .vertical], @ViewBuilder content: () -> Content) {} }
public struct NavigationStack<Root: View>: _Leaf { public init(@ViewBuilder root: () -> Root) {} }
public struct ForEach<Data: RandomAccessCollection, ID: Hashable, Content: View>: _Leaf {
    public init(_ data: Data, @ViewBuilder content: @escaping (Data.Element) -> Content) where Data.Element: Identifiable, ID == Data.Element.ID {}
    public init(_ data: Data, id: KeyPath<Data.Element, ID>, @ViewBuilder content: @escaping (Data.Element) -> Content) {}
}
extension ForEach where Data == Range<Int> {
    public init(_ data: Range<Int>, id: KeyPath<Int, ID>, @ViewBuilder content: @escaping (Int) -> Content) {}
}
public struct TabView<SelectionValue: Hashable, Content: View>: _Leaf {
    public init(selection: Binding<SelectionValue>?, @ViewBuilder content: () -> Content) {}
}
public protocol TabViewStyle {}
public struct PageTabViewStyle: TabViewStyle {
    public struct IndexDisplayMode { public static let automatic = IndexDisplayMode(), always = IndexDisplayMode(), never = IndexDisplayMode() }
}
extension TabViewStyle where Self == PageTabViewStyle {
    public static var page: PageTabViewStyle { PageTabViewStyle() }
    public static func page(indexDisplayMode: PageTabViewStyle.IndexDisplayMode) -> PageTabViewStyle { PageTabViewStyle() }
}

// MARK: timeline
public protocol TimelineSchedule {}
public struct AnimationTimelineSchedule: TimelineSchedule {}
extension TimelineSchedule where Self == AnimationTimelineSchedule {
    public static var animation: AnimationTimelineSchedule { AnimationTimelineSchedule() }
    public static func animation(minimumInterval: Double? = nil, paused: Bool = false) -> AnimationTimelineSchedule { AnimationTimelineSchedule() }
}
public struct TimelineViewDefaultContext { public var date: Date { Date() } }
public struct TimelineView<Schedule: TimelineSchedule, Content: View>: _Leaf {
    public init(_ schedule: Schedule, @ViewBuilder content: @escaping (TimelineViewDefaultContext) -> Content) {}
}

// MARK: controls
public struct LocalizedStringKey: ExpressibleByStringInterpolation { public init(stringLiteral value: String) {} }
public struct Text: _Leaf {
    public init(verbatim content: String) {}
    @_disfavoredOverload public init<S: StringProtocol>(_ content: S) {}
    public init(_ key: LocalizedStringKey) {}
    public func font(_ font: Font?) -> Text { self }
    public func fontWeight(_ weight: Font.Weight?) -> Text { self }
    public func foregroundStyle<S: ShapeStyle>(_ style: S) -> Text { self }
    public func monospacedDigit() -> Text { self }
}
public struct Image: _Leaf {
    public enum Scale { case small, medium, large }
    public init(systemName: String) {}
}
public struct SymbolRenderingMode { public static let monochrome = SymbolRenderingMode(), palette = SymbolRenderingMode(), hierarchical = SymbolRenderingMode() }
public struct ButtonRole { public static let cancel = ButtonRole(), destructive = ButtonRole() }
public struct Button<Label: View>: _Leaf {
    public init(action: @escaping () -> Void, @ViewBuilder label: () -> Label) {}
    public init(role: ButtonRole?, action: @escaping () -> Void, @ViewBuilder label: () -> Label) {}
}
extension Button where Label == Text {
    public init(_ titleKey: LocalizedStringKey, action: @escaping () -> Void) {}
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, action: @escaping () -> Void) {}
}
public struct Label<Title: View, Icon: View>: _Leaf { public init(@ViewBuilder title: () -> Title, @ViewBuilder icon: () -> Icon) {} }
public struct Menu<Label: View, Content: View>: _Leaf { public init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {} }
public struct Picker<Label: View, SelectionValue: Hashable, Content: View>: _Leaf {}
extension Picker where Label == Text {
    public init(_ titleKey: LocalizedStringKey, selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content) {}
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content) {}
}
public protocol PrimitiveButtonStyle {}
public struct BorderedProminentButtonStyle: PrimitiveButtonStyle {}
public struct BorderedButtonStyle: PrimitiveButtonStyle {}
public struct PlainButtonStyle: PrimitiveButtonStyle {}
extension PrimitiveButtonStyle where Self == BorderedProminentButtonStyle { public static var borderedProminent: BorderedProminentButtonStyle { .init() } }
extension PrimitiveButtonStyle where Self == BorderedButtonStyle { public static var bordered: BorderedButtonStyle { .init() } }
extension PrimitiveButtonStyle where Self == PlainButtonStyle { public static var plain: PlainButtonStyle { .init() } }

// MARK: toolbar
public protocol ToolbarContent {}
public struct ToolbarItemPlacement { public static let automatic = ToolbarItemPlacement(), primaryAction = ToolbarItemPlacement(), cancellationAction = ToolbarItemPlacement(), confirmationAction = ToolbarItemPlacement() }
public struct ToolbarItem<ID, Content: View>: ToolbarContent {
    public init(placement: ToolbarItemPlacement = .automatic, @ViewBuilder content: () -> Content) where ID == Void {}
}
public struct _ToolbarTuple<T>: ToolbarContent {}
extension Optional: ToolbarContent where Wrapped: ToolbarContent {}
@resultBuilder public enum ToolbarContentBuilder {
    public static func buildExpression<C: ToolbarContent>(_ c: C) -> C { c }
    public static func buildBlock<C: ToolbarContent>(_ c: C) -> C { c }
    public static func buildBlock<each C: ToolbarContent>(_ c: repeat each C) -> _ToolbarTuple<(repeat each C)> { fatalError() }
    public static func buildIf<C: ToolbarContent>(_ c: C?) -> C? { c }
}

// MARK: state
@propertyWrapper public struct Binding<Value> {
    public var wrappedValue: Value { get { fatalError() } nonmutating set {} }
    public var projectedValue: Binding<Value> { self }
    public init(get: @escaping () -> Value, set: @escaping (Value) -> Void) {}
}
@propertyWrapper public struct State<Value> {
    public init(wrappedValue: Value) {}
    public init(initialValue: Value) {}
    public var wrappedValue: Value { get { fatalError() } nonmutating set {} }
    public var projectedValue: Binding<Value> { fatalError() }
}
@propertyWrapper public struct AppStorage<Value> {
    public var wrappedValue: Value { get { fatalError() } nonmutating set {} }
    public var projectedValue: Binding<Value> { fatalError() }
    public init(wrappedValue: Value, _ key: String, store: UserDefaults? = nil) where Value == Bool {}
    public init(wrappedValue: Value, _ key: String, store: UserDefaults? = nil) where Value == String {}
    public init(wrappedValue: Value, _ key: String, store: UserDefaults? = nil) where Value == Int {}
}
public struct DismissAction { public func callAsFunction() {} }
public struct EnvironmentValues {
    public var dismiss: DismissAction { DismissAction() }
    public var accessibilityReduceMotion: Bool { false }
    public var locale: Locale { get { Locale.current } set {} }
}
@propertyWrapper public struct Environment<Value> {
    public init(_ keyPath: KeyPath<EnvironmentValues, Value>) {}
    public var wrappedValue: Value { fatalError() }
}
public struct Animation: Equatable, Sendable {
    public static let `default` = Animation()
    public static func easeOut(duration: TimeInterval) -> Animation { Animation() }
    public static func easeInOut(duration: TimeInterval) -> Animation { Animation() }
    public static func linear(duration: TimeInterval) -> Animation { Animation() }
}
public func withAnimation<Result>(_ animation: Animation? = .default, _ body: () throws -> Result) rethrows -> Result { try body() }
public struct AnyTransition { public static let opacity = AnyTransition(), identity = AnyTransition() }
public struct AccessibilityTraits: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let isHeader = AccessibilityTraits(rawValue: 1), isSelected = AccessibilityTraits(rawValue: 2), isButton = AccessibilityTraits(rawValue: 4)
}
public struct AccessibilityChildBehavior { public static let ignore = AccessibilityChildBehavior(), contain = AccessibilityChildBehavior(), combine = AccessibilityChildBehavior() }
public enum NavigationBarTitleDisplayMode { case automatic, inline, large }

// MARK: modifiers
extension View {
    public func frame(width: CGFloat? = nil, height: CGFloat? = nil, alignment: Alignment = .center) -> some View { _Modified<Self>() }
    public func frame(minWidth: CGFloat? = nil, idealWidth: CGFloat? = nil, maxWidth: CGFloat? = nil, minHeight: CGFloat? = nil, idealHeight: CGFloat? = nil, maxHeight: CGFloat? = nil, alignment: Alignment = .center) -> some View { _Modified<Self>() }
    public func padding(_ edges: Edge.Set = .all, _ length: CGFloat? = nil) -> some View { _Modified<Self>() }
    public func padding(_ length: CGFloat) -> some View { _Modified<Self>() }
    public func offset(x: CGFloat = 0, y: CGFloat = 0) -> some View { _Modified<Self>() }
    public func rotationEffect(_ angle: Angle, anchor: Alignment = .center) -> some View { _Modified<Self>() }
    public func opacity(_ opacity: Double) -> some View { _Modified<Self>() }
    public func aspectRatio(_ ratio: CGFloat? = nil, contentMode: Int) -> some View { _Modified<Self>() }
    public func clipShape<S: Shape>(_ shape: S, style: FillStyle = FillStyle()) -> some View { _Modified<Self>() }
    public func shadow(color: Color = Color.black, radius: CGFloat, x: CGFloat = 0, y: CGFloat = 0) -> some View { _Modified<Self>() }

    public func overlay<V: View>(alignment: Alignment = .center, @ViewBuilder content: () -> V) -> some View { _Modified<Self>() }
    @_disfavoredOverload public func overlay<Overlay: View>(_ overlay: Overlay, alignment: Alignment = .center) -> some View { _Modified<Self>() }
    public func overlay<S: ShapeStyle>(_ style: S, ignoresSafeAreaEdges edges: Edge.Set = .all) -> some View { _Modified<Self>() }
    public func background<V: View>(alignment: Alignment = .center, @ViewBuilder content: () -> V) -> some View { _Modified<Self>() }
    @_disfavoredOverload public func background<Background: View>(_ background: Background, alignment: Alignment = .center) -> some View { _Modified<Self>() }
    public func background<S: ShapeStyle>(_ style: S, ignoresSafeAreaEdges edges: Edge.Set = .all) -> some View { _Modified<Self>() }
    public func background<S: ShapeStyle, T: InsettableShape>(_ style: S, in shape: T, fillStyle: FillStyle = FillStyle()) -> some View { _Modified<Self>() }

    public func font(_ font: Font?) -> some View { _Modified<Self>() }
    public func foregroundStyle<S: ShapeStyle>(_ style: S) -> some View { _Modified<Self>() }
    public func foregroundStyle<S1: ShapeStyle, S2: ShapeStyle>(_ primary: S1, _ secondary: S2) -> some View { _Modified<Self>() }
    public func tint(_ tint: Color?) -> some View { _Modified<Self>() }
    public func multilineTextAlignment(_ alignment: TextAlignment) -> some View { _Modified<Self>() }
    public func fixedSize(horizontal: Bool, vertical: Bool) -> some View { _Modified<Self>() }
    public func lineLimit(_ number: Int?) -> some View { _Modified<Self>() }
    public func minimumScaleFactor(_ factor: CGFloat) -> some View { _Modified<Self>() }
    public func imageScale(_ scale: Image.Scale) -> some View { _Modified<Self>() }
    public func symbolRenderingMode(_ mode: SymbolRenderingMode?) -> some View { _Modified<Self>() }
    public func buttonStyle<S: PrimitiveButtonStyle>(_ style: S) -> some View { _Modified<Self>() }
    public func disabled(_ disabled: Bool) -> some View { _Modified<Self>() }
    public func id<ID: Hashable>(_ id: ID) -> some View { _Modified<Self>() }
    public func tag<V: Hashable>(_ tag: V) -> some View { _Modified<Self>() }
    public func tabViewStyle<S: TabViewStyle>(_ style: S) -> some View { _Modified<Self>() }
    public func animation<V: Equatable>(_ animation: Animation?, value: V) -> some View { _Modified<Self>() }
    public func transition(_ t: AnyTransition) -> some View { _Modified<Self>() }

    public func accessibilityHidden(_ hidden: Bool) -> some View { _Modified<Self>() }
    public func accessibilityElement(children: AccessibilityChildBehavior = .ignore) -> some View { _Modified<Self>() }
    public func accessibilityLabel(_ labelKey: LocalizedStringKey) -> some View { _Modified<Self>() }
    @_disfavoredOverload public func accessibilityLabel<S: StringProtocol>(_ label: S) -> some View { _Modified<Self>() }
    public func accessibilityValue(_ valueKey: LocalizedStringKey) -> some View { _Modified<Self>() }
    @_disfavoredOverload public func accessibilityValue<S: StringProtocol>(_ value: S) -> some View { _Modified<Self>() }
    public func accessibilityAddTraits(_ traits: AccessibilityTraits) -> some View { _Modified<Self>() }

    public func navigationTitle(_ titleKey: LocalizedStringKey) -> some View { _Modified<Self>() }
    @_disfavoredOverload public func navigationTitle<S: StringProtocol>(_ title: S) -> some View { _Modified<Self>() }
    public func navigationBarTitleDisplayMode(_ mode: NavigationBarTitleDisplayMode) -> some View { _Modified<Self>() }
    public func toolbar<Content: ToolbarContent>(@ToolbarContentBuilder content: () -> Content) -> some View { _Modified<Self>() }
    public func sheet<Content: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil, @ViewBuilder content: @escaping () -> Content) -> some View { _Modified<Self>() }
    public func safeAreaInset<V: View>(edge: VerticalEdge, alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil, @ViewBuilder content: () -> V) -> some View { _Modified<Self>() }
}
