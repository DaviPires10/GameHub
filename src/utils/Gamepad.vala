/*
This file is part of GameHub.
Copyright (C) 2018-2019 Anatoliy Kashkin

GameHub is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

GameHub is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with GameHub.  If not, see <https://www.gnu.org/licenses/>.
*/

using Gdk;
using Gee;

namespace GameHub.Utils.Gamepad
{
	public const int KEY_EVENT_EMIT_INTERVAL = 150000;
	public const int KEY_UP_EMIT_TIMEOUT = 150000;

	public static HashMap<uint16, Button> Buttons;
	public static HashMap<uint16, Axis> Axes;
	public static HashMap<uint, uint16> Keycodes;
	public static bool IsButtonPressed = false;
	public static GLib.List<uint16> ButtonsPressed;

	public static Button BTN_A;
	public static Button BTN_B;
	public static Button BTN_X;
	public static Button BTN_Y;

	public static Button BUMPER_LEFT;
	public static Button BUMPER_RIGHT;

	public static Button BTN_SELECT;
	public static Button BTN_START;
	public static Button BTN_GUIDE;

	public static Button DPAD_UP;
	public static Button DPAD_DOWN;
	public static Button DPAD_LEFT;
	public static Button DPAD_RIGHT;

	public static Axis AXIS_LS_X;
	public static Axis AXIS_LS_Y;
	public static Axis AXIS_RS_X;
	public static Axis AXIS_RS_Y;

	public static void init()
	{
		Buttons = new HashMap<uint16, Button>();
		Axes = new HashMap<uint16, Axis>();
		Keycodes = new HashMap<uint, uint16>();
		ButtonsPressed = new GLib.List<uint16>();

		Keycodes[Key.Up] = 0x6f;
		Keycodes[Key.Down] = 0x74;
		Keycodes[Key.Left] = 0x71;
		Keycodes[Key.Right] = 0x72;

		Keycodes[Key.Return] = 0x24;
		Keycodes[Key.Escape] = 0x9;
		Keycodes[Key.Menu] = 0x87;
		Keycodes[Key.Tab] = 0x17;

		Keycodes[Key.F1] = 0x43;
		Keycodes[Key.F2] = 0x44;

		Keycodes[Key.N] = 0x39;
		Keycodes[Key.S] = 0x27;
		Keycodes[Key.Q] = 0x18;
		Keycodes[Key.E] = 0x1a;

		BTN_A = b(0x130, "A", null, { Key.Return });
		BTN_B = b(0x131, "B", null, { Key.Escape });
		BTN_Y = b(0x133, "Y", null, { Key.E }, ModifierType.CONTROL_MASK);
		BTN_X = b(0x134, "X", null, { Key.Menu });

		BUMPER_LEFT  = b(0x136, "LB", "Left Bumper", { Key.F1 });
		BUMPER_RIGHT = b(0x137, "RB", "Right Bumper", { Key.F2 });

		BTN_SELECT = b(0x13a, "Select", null, { Key.N }, ModifierType.CONTROL_MASK);
		BTN_START  = b(0x13b, "Start", null, { Key.S }, ModifierType.CONTROL_MASK);
		BTN_GUIDE  = b(0x13c, "Guide", null, {Key.Q});

		DPAD_UP    = b(0x220, "Up", "D-Pad Up", { Key.Up });
		DPAD_DOWN  = b(0x221, "Down", "D-Pad Down", { Key.Down });
		DPAD_LEFT  = b(0x222, "Left", "D-Pad Left", { Key.Left });
		DPAD_RIGHT = b(0x223, "Right", "D-Pad Right", { Key.Right });

		AXIS_LS_X = a(0x0, "LS X", "Left Stick X", Key.Left, Key.Right);
		AXIS_LS_Y = a(0x1, "LS Y", "Left Stick Y", Key.Up, Key.Down);
	}

	private static Button b(uint16 code, string name, string? long_name=null, uint[] keys={}, ModifierType? mod=null)
	{
		var btn = new Button(code, name, long_name, keys, mod);
		Buttons.set(code, btn);
		return btn;
	}

	private static Axis a(uint16 code, string name, string? long_name=null, uint negative_key=0, uint positive_key=0, double key_threshold=0.5)
	{
		var axis = new Axis(code, name, long_name, negative_key, positive_key, key_threshold);
		Axes.set(code, axis);
		return axis;
	}

	public class Button: Object
	{
		public uint16 code { get; construct; }
		public string name { get; construct; }
		public string long_name { get; construct; }
		public uint[] keys;
		public ModifierType? mod;

		public Button(uint16 code, string name, string? long_name=null, uint[] keys={}, ModifierType? mod=null)
		{
			Object(code: code, name: name, long_name: long_name ?? name);
			this.keys = keys;
			this.mod = mod;
		}

		public void emit_key_event()
		{
			foreach(var key in keys)
			{
				Gamepad.emit_key_event(key, mod);
			}
		}
	}

	public class Axis: Object
	{
		public uint16 code { get; construct; }
		public string name { get; construct; }
		public string long_name { get; construct; }
		public uint negative_key { get; construct; }
		public uint positive_key { get; construct; }
		public double key_threshold { get; construct; }

		private double _value = 0;
		private int _value_sign = 0;
		private int _pressed_sign = 0;
		private bool _sign_changed = false;

		private Timer timer = new Timer();

		public double value
		{
			get
			{
				return _value;
			}
			set
			{
				int sign = value < - key_threshold ? -1 : (value > key_threshold ? 1 : 0);
				_sign_changed = _value_sign == sign;
				_value_sign = sign;
				_value = value;
			}
		}

		public Axis(uint16 code, string name, string? long_name=null, uint negative_key=0, uint positive_key=0, double key_threshold=0.5)
		{
			Object(code: code, name: name, long_name: long_name ?? name, negative_key: negative_key, positive_key: positive_key, key_threshold: key_threshold);
		}

		public void emit_key_event()
		{
			if(negative_key == 0 && positive_key == 0) return;

			ulong last_update;
			timer.elapsed(out last_update);
			if(_value_sign == 0 && last_update >= Gamepad.KEY_UP_EMIT_TIMEOUT)
			{
				if(_pressed_sign < 0) Gamepad.emit_key_event(negative_key);
				if(_pressed_sign > 0) Gamepad.emit_key_event(positive_key);

				timer.stop();
				_value = 0;
				_value_sign = 0;
				_pressed_sign = 0;
				_sign_changed = false;
				return;
			}

			if(!_sign_changed) return;

			if(_value_sign < 0)
			{
				Gamepad.emit_key_event(positive_key);
				Gamepad.emit_key_event(negative_key);
				_pressed_sign = -1;
			}
			else if(_value_sign > 0)
			{
				Gamepad.emit_key_event(negative_key);
				Gamepad.emit_key_event(positive_key);
				_pressed_sign = 1;
			}
			else
			{
				if(_pressed_sign < 0) Gamepad.emit_key_event(negative_key);
				if(_pressed_sign > 0) Gamepad.emit_key_event(positive_key);
				_pressed_sign = 0;
			}

			_sign_changed = false;
			timer.start();
		}
	}

	private static void emit_key_event(uint keyval, ModifierType? mod=null)
	{
		if(keyval == 0) return;

		if(0x13c == ButtonsPressed.nth_data(0) && keyval == Key.Escape)
		{
			keyval = Key.Q;
			mod = ModifierType.CONTROL_MASK;
		}

		foreach(var wnd in Gtk.Window.list_toplevels())
		if(wnd.is_active)
		{
			Display display = Display.get_default();
			Seat seat = display.get_default_seat();
			Device keyboard = seat.get_keyboard();
			EventKey event = new Event(EventType.KEY_PRESS).key;

			if(mod != null)
			event.state = mod;
			event.keyval = keyval;
			event.hardware_keycode = Keycodes[keyval];
			event.set_device(keyboard);
			event.time = CURRENT_TIME;

			foreach(var window in wnd.get_screen().get_toplevel_windows())
			if(window.is_visible())
			{
				event.window = window;
				break;
			}

			event.put();

			debug("Keyval: %u", keyval);
			debug("Keycode: %u", Keycodes.get(keyval));

			Gamepad.IsButtonPressed = true;
			break;
		}
	}
}
