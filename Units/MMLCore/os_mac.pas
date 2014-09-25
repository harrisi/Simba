{
	This file is part of the Mufasa Macro Library (MML)
	Copyright (c) 2009-2012 by Raymond van Venetië and Merlijn Wajer

    MML is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    MML is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with MML.  If not, see <http://www.gnu.org/licenses/>.

	See the file COPYING, included in this distribution,
	for details about the copyright.

      Linux OS specific implementation for Mufasa Macro Library
}
{$mode objfpc}{$H+}
{$modeswitch objectivec2}
unit os_mac;

{
  TODO's:
  - Allow selecting a different X display
  - Fix keyboard layout / SendString
}

interface

  uses
    Classes, SysUtils, mufasatypes, mufasabase, IOManager,
    CocoaAll, MacOSAll, CarbonProc;

  type

    TNativeWindow = CGWindowId;

    { TWindow }

    TWindow = class(TWindow_Abstract)
      public
        constructor Create(windowId: CGWindowId);
        destructor Destroy; override;
        procedure GetTargetDimensions(out w, h: integer); override;
        procedure GetTargetPosition(out left, top: integer); override;
        function ReturnData(xs, ys, width, height: Integer): TRetData; override;
        procedure FreeReturnData; override;

        function  GetError: String; override;
        function  ReceivedError: Boolean; override;
        procedure ResetError; override;

        function TargetValid: boolean; override;

        function MouseSetClientArea(x1, y1, x2, y2: integer): boolean; override;
        procedure MouseResetClientArea; override;
        function ImageSetClientArea(x1, y1, x2, y2: integer): boolean; override;
        procedure ImageResetClientArea; override;

        procedure ActivateClient; override;
        procedure GetMousePosition(out x,y: integer); override;
        procedure MoveMouse(x,y: integer); override;
        procedure HoldMouse(x,y: integer; button: TClickType); override;
        procedure ReleaseMouse(x,y: integer; button: TClickType); override;
        function  IsMouseButtonHeld( button : TClickType) : boolean;override;

        procedure SendString(str: string; keywait, keymodwait: integer); override;
        procedure HoldKey(key: integer); override;
        procedure ReleaseKey(key: integer); override;
        function IsKeyHeld(key: integer): boolean; override;
        function GetKeyCode(c : char) : integer;override;

        function GetNativeWindow: TNativeWindow;
        function GetHandle(): PtrUInt;
      private
        { windowId is the id of our window }
        windowId: CGWindowId;

        { Dictionary of chars to key codes }
        CharCodeDict: CFDictionaryRef;

        { (Forced) Client Area }
        mx1, my1, mx2, my2: integer;
        ix1, iy1, ix2, iy2: integer;
        mcaset, icaset: Boolean;

        procedure MouseApplyAreaOffset(var x, y: integer);
        procedure ImageApplyAreaOffset(var x, y: integer);
        function GetMacKeyCode(Key: Word): CGKeyCode;
        function WindowRect: CGRect;
    end;

    TIOManager = class(TIOManager_Abstract)
      public
        constructor Create;
        constructor Create(plugin_dir: string);
        function SetTarget(target: TNativeWindow): integer; overload;
        procedure SetDesktop; override;

        function GetProcesses: TSysProcArr; override;
        procedure SetTargetEx(Proc: TSysProc); overload;
      protected
        DesktopWindowId: CGWindowId;
        procedure NativeInit; override;
        procedure NativeFree; override;
    end;

implementation

  uses GraphType, interfacebase, lcltype;

  function CreateStringForKey(Key: CGKeyCode): CFStringRef;
  var
    currentKeyboard: TISInputSourceRef;
    layoutData: CFDataRef;
    keyboardLayout: ^UCKeyboardLayout;
    keysDown: UInt32;
    chars: array [0..3] of UniChar;
    realLength: UniCharCount;
  begin
    currentKeyboard := TISCopyCurrentKeyboardInputSource();
    layoutData :=
        TISGetInputSourceProperty(currentKeyboard,
                                  kTISPropertyUnicodeKeyLayoutData);
    keyboardLayout := CFDataGetBytePtr(layoutData);

    keysDown := 0;

    UCKeyTranslate(keyboardLayout^,
                   Key,
                   kUCKeyActionDisplay,
                   0,
                   LMGetKbdType(),
                   kUCKeyTranslateNoDeadKeysBit,
                   keysDown,
                   round(sizeof(chars) / sizeof(chars[0])),
                   realLength,
                   chars);
    CFRelease(currentKeyboard);

    Result := CFStringCreateWithCharacters(kCFAllocatorDefault, chars, 1);
  end;

  function CreateCharCodeDict: CFDictionaryRef;
  var
    i: Integer;
    str: CFStringRef;
  begin
    Result := CFDictionaryCreateMutable(kCFAllocatorDefault,
                                                 128,
                                                 @kCFCopyStringDictionaryKeyCallBacks,
                                                 nil);

    { Loop through every keycode (0 - 127) to find its current mapping. }
    for i := 0 to 127 do
    begin
      str := CreateStringForKey(CGKeyCode(i));
      //NSLog(NSSTR('%ld: %@'), i, str);
      if not (str = nil) then
      begin
          CFDictionaryAddValue(Result, str, UnivPtr(i));
          CFRelease(str);
      end;
    end;
  end;

  function TWindow.GetMacKeyCode(Key: Word): CGKeyCode;
  var
    code: CGKeyCode;
    character: UniChar;
    charStr: CFStringRef;
    i: size_t;
  begin
    if ((Key < 48) or (Key > 90)) then
    begin
      Result := VirtualKeyCodeToMac(Key);
      Exit;
    end;

    character := Word(LowerCase(Char(Key)));
    charStr := CFSTR(@character);

     //NSLog(NSSTR('%@'), charStr);
    if not (CFDictionaryGetValueIfPresent(CharCodeDict, charStr,
                                       @code)) then
    begin
        code := -1;
    end;

    CFRelease(charStr);
    Result := code;
  end;

  function TWindow.WindowRect: CGRect;
  var
    windowInfoArr: CFArrayRef;
    windowArr: CFMutableArrayRef;
    windowInfo, windowBounds: CFDictionaryRef;
  begin
    // In carbon you have to pass an array of window ids that you want information about
    windowArr := CFArrayCreateMutable(nil, 1, nil);
    CFArrayAppendValue(windowArr, UnivPtr(windowId));

    windowInfoArr := CGWindowListCreateDescriptionFromArray(windowArr);
    if (CFArrayGetCount(windowInfoArr) < 1) then
    begin
        Exit(CGRectNull);
    end;
    windowInfo := CFDictionaryRef(CFArrayGetValueAtIndex(windowInfoArr, 0));
    windowBounds := CFDictionaryRef(CFDictionaryGetValue(windowInfo, kCGWindowBounds));

    CGRectMakeWithDictionaryRepresentation(windowBounds, Result);
  end;

  { TWindow }

  function TWindow.GetError: String;
  begin
    // Error handling?
  end;

  function  TWindow.ReceivedError: Boolean;
  begin
     Result := False;
  end;

  procedure TWindow.ResetError;
  begin
  end;

  { See if the semaphores / CS are initialised }
  constructor TWindow.Create(windowId: CGWindowId);
  begin
    inherited Create;
    self.windowId := windowId;

    self.CharCodeDict := CreateCharCodeDict;

    self.mx1 := 0; self.my1 := 0; self.mx2 := 0; self.my2 := 0;
    self.mcaset := false;
    self.ix1 := 0; self.iy1 := 0; self.ix2 := 0; self.iy2 := 0;
    self.icaset := false;
  end;

  destructor TWindow.Destroy;
  begin
    FreeReturnData;
    inherited Destroy;
  end;

  function TWindow.GetNativeWindow: TNativeWindow;
  begin
    Exit(windowId);
  end;

  function TWindow.GetHandle(): PtrUInt;
  begin
    Result := PtrUInt(GetNativeWindow());
  end;

  procedure TWindow.GetTargetDimensions(out w, h: integer);
  var
    rect: CGRect;
  begin
    if icaset then
    begin
      w := ix2 - ix1;
      h := iy2 - iy1;
      exit;
    end;

    rect := WindowRect;

    w := round(rect.size.width);
    h := round(rect.size.height);
  end;

  procedure TWindow.GetTargetPosition(out left, top: integer);
  var
    rect: CGRect;
  begin
    rect := WindowRect;

    left := round(rect.origin.x);
    top := round(rect.origin.y);
  end;

  function TWindow.TargetValid: boolean;
  var
    rect: CGRect;
  begin
    Result := not Boolean(CGRectIsNull(WindowRect));
  end;

  { SetClientArea allows you to use a part of the actual client as a virtual
    client. Im other words, all mouse,find functions will be relative to the
    virtual client.

    XXX:
    I realise I can simply add a[x,y]1 to all of the functions rather than check
    for caset (since they're 0 if it's not set), but I figured it would be more
    clear this way.
  }
  function TWindow.MouseSetClientArea(x1, y1, x2, y2: integer): boolean;
  var w, h: integer;
  begin
    { TODO: What if the client resizes (shrinks) and our ``area'' is too large? }
    GetTargetDimensions(w, h);
    if ((x2 - x1) > w) or ((y2 - y1) > h) then
      exit(False);
    if (x1 < 0) or (y1 < 0) then
      exit(False);

    mx1 := x1; my1 := y1; mx2 := x2; my2 := y2;
    mcaset := True;
  end;

  procedure TWindow.MouseResetClientArea;
  begin
    mx1 := 0; my1 := 0; mx2 := 0; my2 := 0;
    mcaset := False;
  end;

  function TWindow.ImageSetClientArea(x1, y1, x2, y2: integer): boolean;
  var w, h: integer;
  begin
    { TODO: What if the client resizes (shrinks) and our ``area'' is too large? }
    GetTargetDimensions(w, h);
    if ((x2 - x1) > w) or ((y2 - y1) > h) then
      exit(False);
    if (x1 < 0) or (y1 < 0) then
      exit(False);

    ix1 := x1; iy1 := y1; ix2 := x2; iy2 := y2;
    icaset := True;
  end;

  procedure TWindow.ImageResetClientArea;
  begin
    ix1 := 0; iy1 := 0; ix2 := 0; iy2 := 0;
    icaset := False;
  end;

  procedure TWindow.MouseApplyAreaOffset(var x, y: integer);
  begin
    if mcaset then
    begin
      x := x + mx1;
      y := y + my1;
    end;
  end;

  procedure TWindow.ImageApplyAreaOffset(var x, y: integer);
  begin
    if icaset then
    begin
      x := x + ix1;
      y := y + iy1;
    end;
  end;

  procedure TWindow.ActivateClient;

  begin
    {XSetInputFocus(display,window,RevertToParent,CurrentTime);
    XFlush(display);
    if ReceivedError then
      raise Exception.Create('Error: ActivateClient: ' + GetError); }
  end;

  function TWindow.ReturnData(xs, ys, width, height: Integer): TRetData;
  var
    w, h: integer;
    rect: CGRect;
    imageRef: CGImageRef;
    data: CFDataRef;
  begin
    GetTargetDimensions(w,h);
    if (xs < 0) or (xs + width > w) or (ys < 0) or (ys + height > h) then
      raise Exception.CreateFMT('TMWindow.ReturnData: The parameters passed are wrong; xs,ys %d,%d width,height %d,%d',[xs,ys,width,height]);

    ImageApplyAreaOffset(xs, ys);

    rect := CGRectMake(xs, ys, width, height);
    imageRef := CGWindowListCreateImage(rect, kCGWindowListOptionOnScreenOnly, kCGNullWindowID, kCGWindowImageShouldBeOpaque);
    data := CGDataProviderCopyData(CGImageGetDataProvider(imageRef));

    Result.Ptr := CFDataGetBytePtr(data);
    Result.IncPtrWith := 0;
    Result.RowLen := width;
    //XSetErrorHandler(Old_Handler);
  end;

  procedure TWindow.FreeReturnData;
  begin
  end;

  procedure TWindow.GetMousePosition(out x,y: integer);
  var
    event: CGEventRef;
    point: CGPoint;
  begin
    event := CGEventCreate(nil);
    point := CGEventGetLocation(event);

    x := round(point.x);
    y := round(point.y);

    x := x - mx1;
    y := y - my1;
  end;

  procedure TWindow.MoveMouse(x,y: integer);
  var
    point: CGPoint;
    event: CGEventRef;
  begin
    MouseApplyAreaOffset(x, y);
    point := CGPointMake(x, y);
    event := CGEventCreateMouseEvent( nil, {kCGEventMouseMoved}5, point, 0);
    CGEventPost(kCGSessionEventTap, event);
    CFRelease(event);
  end;

  // Test middle button
  procedure TWindow.HoldMouse(x,y: integer; button: TClickType);
  var
    event: CGEventRef;
    point: CGPoint;
    eventType, mouseButton: LongInt;
  begin
    case button of
      mouse_Left:
        begin
          eventType := 1 {kCGEventLeftMouseDown};
          mouseButton := kCGMouseButtonLeft;
        end;
      mouse_Middle:
        begin
          eventType := 25 {kCGEventOtherMouseDown};
          mouseButton := kCGMouseButtonCenter;
        end;
      mouse_Right:
        begin
          eventType := 3 {kCGEventRightMouseDown};
          mouseButton := kCGMouseButtonRight;
        end;
    end;

    point := CGPointMake(x, y);
    event := CGEventCreateMouseEvent(nil, eventType, point, mouseButton);
    CGEventPost(kCGSessionEventTap, event);
    CFRelease(event);
  end;

  // Test middle button
  procedure TWindow.ReleaseMouse(x,y: integer; button: TClickType);
  var
    event: CGEventRef;
    point: CGPoint;
    eventType, mouseButton: LongInt;
  begin
    case button of
      mouse_Left:
        begin
          eventType := 2 {kCGEventLeftMouseUp};
          mouseButton := kCGMouseButtonLeft;
        end;
      mouse_Middle:
        begin
          eventType := 26 {kCGEventOtherMouseUp};
          mouseButton := kCGMouseButtonCenter;
        end;
      mouse_Right:
        begin
          eventType := 4 {kCGEventRightMouseUp};
          mouseButton := kCGMouseButtonRight;
        end;
    end;

    point := CGPointMake(x, y);
    event := CGEventCreateMouseEvent(nil, eventType, point, mouseButton);
    CGEventPost(kCGSessionEventTap, event);
    CFRelease(event);
  end;

  // Test middle button
  function TWindow.IsMouseButtonHeld(button: TClickType): boolean;
  var
    mouseButton: UInt32;
    buttonStateResult: CBool;
  begin
    case button of
      mouse_Left:   mouseButton := kCGMouseButtonLeft;
      mouse_Middle: mouseButton := kCGMouseButtonCenter;
      mouse_Right:  mouseButton := kCGMouseButtonRight;
      else
        Result := False;
    end;

    buttonStateResult := CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, mouseButton);
    Result := buttonStateResult > 0;
  end;

  { TODO: Check if this supports multiple keyboard layouts, probably not }
  procedure TWindow.SendString(str: string; keywait, keymodwait: integer);
  var
    I, L: Integer;
    K: Byte;
    HoldShift: Boolean;
  begin
    HoldShift := False;
    L := Length(str);
    for I := 1 to L do
    begin
      if (((str[I] >= 'A') and (str[I] <= 'Z')) or
          ((str[I] >= '!') and (str[I] <= '&')) or
          ((str[I] >= '(') and (str[I] <= '+')) or
          (str[I] = ':') or
          ((str[I] >= '<') and (str[I] <= '@')) or
          ((str[I] >= '^') and (str[I] <= '_')) or
          ((str[I] >= '{') and (str[I] <= '~'))) then
      begin
        HoldKey(VK_SHIFT);
        HoldShift := True;
        sleep(keymodwait shr 1);
      end;

      K := GetKeyCode(str[I]);
      HoldKey(K);

      if keywait <> 0 then
        Sleep(keywait);

      ReleaseKey(K);

      if (HoldShift) then
      begin
        HoldShift := False;
        sleep(keymodwait shr 1);
        ReleaseKey(VK_SHIFT);
      end;
    end;
  end;

  procedure TWindow.HoldKey(key: integer);
  var
    event: CGEventRef;
    character: char;
  begin
    event := CGEventCreateKeyboardEvent(nil, GetMacKeyCode(key), Integer(true));
    CGEventPost(kCGSessionEventTap, event);
    CFRelease(event);
  end;

  procedure TWindow.ReleaseKey(key: integer);
  var
    event: CGEventRef;
  begin
    event := CGEventCreateKeyboardEvent(nil, GetMacKeyCode(key), Integer(false));
    CGEventPost(kCGSessionEventTap, event);
    CFRelease(event);
  end;

  function TWindow.IsKeyHeld(key: integer): boolean;
  begin
    Result := Boolean(CGEventSourceKeyState(kCGEventSourceStateCombinedSessionState, GetMacKeyCode(key)));
  end;

  function TWindow.GetKeyCode(c: char): integer;
  begin
    case C of
      '0'..'9' :Result := VK_0 + Ord(C) - Ord('0');
      'a'..'z' :Result := VK_A + Ord(C) - Ord('a');
      'A'..'Z' :Result := VK_A + Ord(C) - Ord('A');
      ' ' : result := VK_SPACE;
    else
      Raise Exception.CreateFMT('GetSimpleKeyCode - char (%s) is not in A..z',[c]);
    end
  end;

  { ***implementation*** IOManager }

  constructor TIOManager.Create;
  begin
    inherited Create;
  end;

  constructor TIOManager.Create(plugin_dir: string);
  begin
    inherited Create(plugin_dir);
  end;

  procedure TIOManager.NativeInit;
  var
    str: PChar;
    windows: CFArrayRef;
    window: CFDictionaryRef;
    windowName: CFStringRef;
    i: integer;
  begin
    {windows := CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    for i := 0 to CFArrayGetCount(windows)-1 do
    begin
      window := CFArrayGetValueAtIndex(windows, i);
      windowName := CFStringRef(CFDictionaryGetValue(window, kCGWindowName));
      if (windowName = nil) then
        continue;
      if (CFStringCompare(windowName, CFSTR('Desktop'), 0) = kCFCompareEqualTo) then
        break;
    end;
    self.DesktopWindowId := CGWindowId(CFDictionaryGetValue(window, kCGWindowNumber)^);}
    self.DesktopWindowId := 2;
  end;

  procedure TIOManager.NativeFree;
  begin
  end;

  procedure TIOManager.SetDesktop;
  begin
    SetBothTargets(TWindow.Create(DesktopWindowId));
  end;

  function TIOManager.SetTarget(target: CGWindowId): integer;
  begin
    result := SetBothTargets(TWindow.Create(target))
  end;

  function TIOManager.GetProcesses: TSysProcArr;
  begin
    raise Exception.Create('GetProcesses: Not Implemented.');
  end;

  procedure TIOManager.SetTargetEx(Proc: TSysProc);
  begin
    raise Exception.Create('SetTargetEx: Not Implemented.');
  end;

end.
