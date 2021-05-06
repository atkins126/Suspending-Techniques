unit SuspendMe.SelfDebug;

{
  This module demonstrates how a process can registered as a debugger for
  itself, so that no other program can attach to it.
}

interface

uses
  Winapi.WinNt, NtUtils;

const
  DEFAULT_SELF_DEBUG_TIMEOUT = 8000 * MILLISEC;

// Attach a debug port to the current process and suppress further debug events
function StartSelfDebugging(
  out hxDebugObject: IHandle;
  const Timeout: Int64 = DEFAULT_SELF_DEBUG_TIMEOUT
): TNtxStatus;

implementation

uses
  Ntapi.ntdef, Ntapi.ntstatus, Winapi.WinError, Ntapi.ntrtl, Ntapi.ntmmapi,
  Ntapi.ntpsapi, NtUtils.Debug, NtUtils.Processes, NtUtils.Sections,
  NtUtils.SysUtils, NtUtils.Processes.Create, NtUtils.Processes.Create.Native,
  NtUtils.Processes.Memory, NtUtils.Threads, NtUtils.Ldr, NtUtils.ImageHlp,
  NtUtils.Synchronization, NtUtils.Objects, NtUtils.Security.Acl,
  DelphiUtils.AutoObject;

function NtCreateThreadEx(
  out ThreadHandle: THandle;
  DesiredAccess: TThreadAccessMask;
  [in, opt] ObjectAttributes: PObjectAttributes;
  ProcessHandle: THandle;
  StartRoutine: TUserThreadStartRoutine;
  [in, opt] Argument: Pointer;
  CreateFlags: TThreadCreateFlags;
  ZeroBits: NativeUInt;
  StackSize: NativeUInt;
  MaximumStackSize: NativeUInt;
  [in, opt] AttributeList: PPsAttributeList
): NTSTATUS; stdcall;
begin
  // Forward the parameters making sure to hide the thread from debugger
  Result := Ntapi.ntpsapi.NtCreateThreadEx(ThreadHandle, DesiredAccess,
    ObjectAttributes, ProcessHandle, StartRoutine, Argument, CreateFlags or
    THREAD_CREATE_FLAGS_HIDE_FROM_DEBUGGER, ZeroBits, StackSize,
    MaximumStackSize, AttributeList);
end;

exports
  // Help resolving names without symbols
  NtCreateThreadEx;

// Make sure local libraries always use our version of thread creation that
// toggles the hide-from-debugger flag
procedure PatchThreadCreation(ModuleBase: PByte; Size: Cardinal);
var
  Import: TArray<TImportDllEntry>;
  i, j: Integer;
  IAT: Pointer;
begin
  if RtlxEnumerateImportImage(Import, ModuleBase, Size, True).IsSuccess then
    for i := 0 to High(Import) do
    begin
      if RtlxCompareAnsiStrings(Import[i].DllName, ntdll) <> 0 then
        Continue;

      for j := 0 to High(Import[i].Functions) do
      begin
        if not Import[i].Functions[j].ImportByName or (RtlxCompareAnsiStrings(
          Import[i].Functions[j].Name, 'NtCreateThreadEx') <> 0)  then
          Continue;

        IAT := ModuleBase + Import[i].IAT + Cardinal(j) * SizeOf(Pointer);

        if NtxProtectMemoryProcess(NtCurrentProcess, IAT, SizeOf(Pointer),
          PAGE_READWRITE).IsSuccess then
          Pointer(IAT^) := @NtCreateThreadEx;
      end;
    end;
end;

// Make sure we avoid generating debug event as much as possible
procedure SuppressDebugEvents;
var
  hxThread: IHandle;
  Module: TModuleEntry;
begin
  hxThread := nil;

  // Mark existing threads so they don't generate debug events
  while NtxGetNextThread(NtCurrentProcess, hxThread, THREAD_SET_INFORMATION)
    .IsSuccess do
    NtxSetThread(hxThread.Handle, ThreadHideFromDebugger, nil, 0);

  // Patch local IATs to use our thread creation that suppresses debug events
  for Module in LdrxEnumerateModules do
    if Module.DllBase <> @ImageBase then
      PatchThreadCreation(Module.DllBase, Module.SizeOfImage);

  // Protecting the page with the MZ header blocks external thread creations
  NtxProtectMemoryProcess(NtCurrentProcess, @ImageBase, 1, PAGE_READONLY or
    PAGE_GUARD);
end;

// The function we execute in a fork (since someone need to respond to the debug
// event out-of-process)
function ForkMain(
  hProcess: THandle;
  hDebugObject: THandle
): TNtxStatus;
var
  Wait: TDbgxWaitState;
  Handles: TDbgxHandles;
begin
  // Start debugging the parent process
  Result := NtxDebugProcess(hProcess, hDebugObject);

  if not Result.IsSuccess then
    Exit;

  // Drain the queue of debug messages without waiting
  repeat
    Result := NtxDebugWait(hDebugObject, Wait, Handles, 0);

    if not Result.IsSuccess or (Result.Status = STATUS_TIMEOUT) then
      Break;

    Result := NtxDebugContinue(hDebugObject, Wait.AppClientId);
  until not Result.IsSuccess;

  // Cancel debugging on failure
  if not Result.IsSuccess then
    NtxDebugProcessStop(hProcess, hDebugObject);
end;

type
  TSharedContext = record
    Status: NTSTATUS;
    Location: PWideChar;
  end;
  PSharedContext = ^TSharedContext;

// All brought together
function StartSelfDebugging;
var
  hxSection, hxProcess: IHandle;
  Mapping: IMemory<PSharedContext>;
  Info: TProcessInfo;
begin
  SuppressDebugEvents;

  // The fork will need a handle to the parent (us)
  Result := NtxOpenCurrentProcess(hxProcess, MAXIMUM_ALLOWED, OBJ_INHERIT);

  if not Result.IsSuccess then
    Exit;

  // We also need a shared a debug port with a denying DACL
  Result := NtxCreateDebugObject(hxDebugObject, False, AttributeBuilder
    .UseAttributes(OBJ_INHERIT)
    .UseSecurity(RtlxAllocateDenyingSd)
  );

  if not Result.IsSuccess then
    Exit;

  Result := NtxCreateSection(hxSection, SizeOf(TSharedContext));

  if not Result.IsSuccess then
    Exit;

  // And a shared memory region
  Result := NtxMapViewOfSection(IMemory(Mapping), hxSection.Handle,
    NtxCurrentProcess);

  if not Result.IsSuccess then
    Exit;

  Mapping.Data.Location := 'Main';
  Mapping.Data.Status := STATUS_UNSUCCESSFUL;

  // Start a fork that will attach as a debugger
  Result := RtlxCloneCurrentProcess(Info);

  if not Result.IsSuccess then
    Exit;

  if Result.Status = STATUS_PROCESS_CLONED then
  try
    // Executing within the fork
    Result := ForkMain(hxProcess.Handle, hxDebugObject.Handle);
    Mapping.Data.Status := Result.Status;

    // Two processes share the same constant strings; no need to marshal them
    if StringRefCount(Result.Location) <= 0 then
      Mapping.Data.Location := PWideChar(Result.Location);
  finally
    NtxTerminateProcess(NtCurrentProcess, STATUS_PROCESS_CLONED);
  end;

  // Wait for fork's completion
  Result := NtxWaitForSingleObject(Info.hxProcess.Handle, Timeout);

  if not Result.IsSuccess then
    Exit;

  if Result.Status = STATUS_TIMEOUT then
  begin
    // Make timeouts unsuccessful
    Result.Win32Error := ERROR_TIMEOUT;
    Exit;
  end;

  // Forward the status from the fork
  Result.Location := 'Fork::' + String(Mapping.Data.Location);
  Result.Status := Mapping.Data.Status;

  if not Result.IsSuccess then
    Exit;

  // Prevent debug object's inheritance
  NtxSetFlagsHandle(hxDebugObject.Handle, False, False);

  writeln('Note that we blocked Ctrl+C because new threads can deadlock us. ' +
    'You can still close the console or terminate the process from an ' +
    'external tool.');
end;

end.
