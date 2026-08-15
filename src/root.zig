// Immediate-mode UI: per-frame region registration, event routing, drawing.
//
// It names no graphics API. What it shares with whoever draws its output is the
// two-dimensional draw list vocabulary in `lenore-resources` — the vertex, the
// draw command, the clip rectangle and the image handle — which both sides name
// and neither owns. Everything below is either the authoring side of that
// vocabulary or the code that writes a list in it.

const canvas = @import("canvas.zig");
const hit_test = @import("hit_test.zig");
const id_stack = @import("id_stack.zig");
const input = @import("input.zig");
const layout = @import("layout.zig");
const primitives = @import("primitives.zig");
const text = @import("text.zig");
const types = @import("types.zig");
const widget_context = @import("widget_context.zig");
const widgets = @import("widgets.zig");

pub const Canvas = canvas.Canvas;
pub const CanvasError = canvas.Error;
pub const CanvasInitError = canvas.InitError;
pub const Checkpoint = canvas.Checkpoint;

pub const Id = id_stack.Id;
pub const IdKey = id_stack.Key;
pub const IdStack = id_stack.Stack;
pub const IdStackError = id_stack.Error;

pub const Region = hit_test.Region;
pub const hitTest = hit_test.hitTest;

pub const ButtonAction = input.ButtonAction;
pub const Event = input.Event;
pub const InputContext = input.Context;
pub const InputError = input.Error;
pub const Interaction = input.Interaction;
pub const Key = input.Key;
pub const KeyAction = input.KeyAction;
pub const KeyEvent = input.KeyEvent;
pub const LookupSlot = input.LookupSlot;
pub const PointerButton = input.PointerButton;
pub const PointerButtonEvent = input.PointerButtonEvent;
pub const Token = input.Token;

pub const Arrangement = layout.Arrangement;
pub const Constraints = layout.Constraints;
pub const CrossAlignment = layout.CrossAlignment;
pub const Dimension = layout.Dimension;
pub const LayoutError = layout.Error;
pub const LayoutNode = layout.Node;
pub const LayoutTree = layout.Tree;
pub const LogicalSize = types.LogicalSize;
pub const MainAlignment = layout.MainAlignment;
pub const NodeIndex = layout.NodeIndex;
pub const Padding = layout.Padding;
pub const Workspace = layout.Workspace;
pub const solveLayout = layout.solve;

pub const addRoundedRect = primitives.addRoundedRect;
pub const addGlyphs = text.addGlyphs;

pub const ButtonStyle = widgets.ButtonStyle;
pub const CheckboxStyle = widgets.CheckboxStyle;
pub const Label = widgets.Label;
pub const LabelStyle = widgets.LabelStyle;
pub const SliderRange = widgets.SliderRange;
pub const SliderStyle = widgets.SliderStyle;
pub const SplitterStyle = widgets.SplitterStyle;
pub const WidgetError = widgets.Error;
pub const drawButton = widgets.drawButton;
pub const drawCheckbox = widgets.drawCheckbox;
pub const drawLabel = widgets.drawLabel;
pub const drawSlider = widgets.drawSlider;
pub const drawSplitter = widgets.drawSplitter;
pub const labelBaseline = widgets.labelBaseline;
pub const sliderFraction = widgets.sliderFraction;
pub const sliderValue = widgets.sliderValue;

pub const RegionOptions = widget_context.RegionOptions;
pub const WidgetContext = widget_context.Context;
pub const WidgetContextError = widget_context.Error;

pub const ConversionError = types.ConversionError;
pub const LogicalRect = types.LogicalRect;
pub const Point = types.Point;
pub const ScaleFactor = types.ScaleFactor;
pub const SrgbColor = types.SrgbColor;
pub const UvRect = types.UvRect;
