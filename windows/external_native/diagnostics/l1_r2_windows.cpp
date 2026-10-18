// COMPILE ONLY. Not linked by any candidate entry or Fake CTest executable.
#include "diagnostics/l1_r2_windows.h"
#include "diagnostics/l1_temporary_handle.h"
#include <aclapi.h>
#include <psapi.h>
#include <sddl.h>
#include <winternl.h>
#include <cwchar>

namespace shiroha_l1_crypto::r2 {
namespace {
ObjectIdentityPin identity(const FILE_ID_INFO &i) {
  ObjectIdentityPin p;p.volume_serial=i.VolumeSerialNumber;
  std::copy_n(i.FileId.Identifier,16,p.file_id.begin());return p;
}
bool same(const WindowsObjectPin &a,const WindowsObjectPin &b) {
  return identity(a.identity)==identity(b.identity);
}
std::string sid_digest(const std::wstring &s) {
  CanonicalHashBuilder h;h.put_str("SHIROHA_L1_R2_ACCOUNT_V1");
  for(wchar_t c:s) h.put_u16_le(uint16_t(c));return h.finalize_hex();
}
bool token_user(HANDLE process,std::wstring &sid) {
  HANDLE token=nullptr;
  if(!OpenProcessToken(process,TOKEN_QUERY,&token))return false;
  TemporaryHandle owner(TemporaryOwner::token_reader,reinterpret_cast<uintptr_t>(token),
      [](uintptr_t h) noexcept { return CloseHandle(reinterpret_cast<HANDLE>(h))!=FALSE; });
  DWORD n=0;
  GetTokenInformation(token,TokenUser,nullptr,0,&n);
  bool ok=false;
  if(n && n<=65536) {
    std::vector<uint8_t> bytes(n);
    if(GetTokenInformation(token,TokenUser,bytes.data(),n,&n)) {
      LPWSTR text=nullptr;
      if(ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER *>(bytes.data())->User.Sid,&text)) {
        sid=text;ok=LocalFree(text)==nullptr;
      }
    }
  }
  const bool closed=owner.close_as(TemporaryOwner::token_reader);return ok&&closed;
}
bool security(const WindowsObjectPin &pin,std::string &out) {
  PSECURITY_DESCRIPTOR sd=nullptr;LPWSTR sddl=nullptr;ULONG n=0;
  PSID owner=nullptr;PACL acl=nullptr;
  if(GetSecurityInfo(pin.handle,SE_FILE_OBJECT,OWNER_SECURITY_INFORMATION|DACL_SECURITY_INFORMATION,
      &owner,nullptr,&acl,nullptr,&sd)!=ERROR_SUCCESS)return false;
  bool ok=owner && IsValidSid(owner) && acl && IsValidAcl(acl) && acl->AceCount<=128;
  LPWSTR owner_text=nullptr;
  ok=ok && ConvertSidToStringSidW(owner,&owner_text) && pin.owner_sid==owner_text;
  if(owner_text) ok=(LocalFree(owner_text)==nullptr)&&ok;
  ok=ok && ConvertSecurityDescriptorToStringSecurityDescriptorW(sd,SDDL_REVISION_1,
      OWNER_SECURITY_INFORMATION|DACL_SECURITY_INFORMATION,&sddl,&n) && n && n<=32768;
  if(ok) {
    CanonicalHashBuilder h;h.put_str("SHIROHA_L1_ARTIFACT_SECURITY_V1");
    for(ULONG i=0;i<n-1;++i)h.put_u16_le(uint16_t(sddl[i]));
    out=h.finalize_hex();
  }
  if(sddl)ok=(LocalFree(sddl)==nullptr)&&ok;
  ok=(LocalFree(sd)==nullptr)&&ok;return ok;
}
bool pin_metadata(const WindowsObjectPin &p,bool directory) {
  FILE_ID_INFO id{};FILE_ATTRIBUTE_TAG_INFO tag{};FILE_STANDARD_INFO s{};
  return p.handle && p.handle!=INVALID_HANDLE_VALUE &&
    GetFileInformationByHandleEx(p.handle,FileIdInfo,&id,sizeof(id)) &&
    identity(id).valid() && identity(id)==identity(p.identity) &&
    GetFileInformationByHandleEx(p.handle,FileAttributeTagInfo,&tag,sizeof(tag)) &&
    !(tag.FileAttributes&FILE_ATTRIBUTE_REPARSE_POINT) &&
    bool(tag.FileAttributes&FILE_ATTRIBUTE_DIRECTORY)==directory &&
    GetFileInformationByHandleEx(p.handle,FileStandardInfo,&s,sizeof(s)) &&
    !s.DeletePending && (directory || s.NumberOfLinks==1);
}
bool child_of(const WindowsObjectPin &child,const WindowsObjectPin &parent) {
  wchar_t a[1024]{},b[1024]{};
  DWORD na=GetFinalPathNameByHandleW(child.handle,a,1024,FILE_NAME_NORMALIZED|VOLUME_NAME_DOS);
  DWORD nb=GetFinalPathNameByHandleW(parent.handle,b,1024,FILE_NAME_NORMALIZED|VOLUME_NAME_DOS);
  if(!na||na>=1024||!nb||nb>=1024||child.identity.VolumeSerialNumber!=parent.identity.VolumeSerialNumber)
    return false;
  std::wstring prefix(b,nb);if(prefix.back()!=L'\\')prefix+=L'\\';
  std::wstring actual(a,na);
  return actual.size()>prefix.size() && actual.compare(0,prefix.size(),prefix)==0 &&
    actual.find(L'\\',prefix.size())==std::wstring::npos;
}
class FileRead final : public ReadPort {
public:
  explicit FileRead(HANDLE h):handle_(h){}
  bool size(uint64_t &n) override {
    FILE_STANDARD_INFO s{};
    if(!GetFileInformationByHandleEx(handle_,FileStandardInfo,&s,sizeof(s)) ||
        s.EndOfFile.QuadPart<=0 || s.DeletePending || s.NumberOfLinks!=1)return false;
    n=uint64_t(s.EndOfFile.QuadPart);return true;
  }
  bool rewind() override {LARGE_INTEGER z{};return SetFilePointerEx(handle_,z,nullptr,FILE_BEGIN)!=FALSE;}
  bool read(uint8_t *p,size_t n,size_t &got) override {
    DWORD r=0;bool ok=ReadFile(handle_,p,DWORD(n),&r,nullptr)!=FALSE;got=r;return ok;
  }
private:HANDLE handle_;
};
bool read_exact(const WindowsObjectPin &p,uint8_t *bytes,DWORD n) {
  LARGE_INTEGER z{};DWORD got=0;
  return inspect_e4_pin(p,false,n) && SetFilePointerEx(p.handle,z,nullptr,FILE_BEGIN) &&
    ReadFile(p.handle,bytes,n,&got,nullptr) && got==n && inspect_e4_pin(p,false,n);
}
bool created_at(HANDLE p,uint64_t &n) {
  FILETIME c{},e{},k{},u{};
  if(!GetProcessTimes(p,&c,&e,&k,&u))return false;
  n=(uint64_t(c.dwHighDateTime)<<32)|c.dwLowDateTime;return n!=0;
}
bool bounded_create(const GrantTarget &t,const WindowsObjectPin &image,
    const WindowsObjectPin &dir,HANDLE *inherited,PROCESS_INFORMATION &result) {
  // Hashing/parent/identity checks belong to the bounded adapter BEFORE here.
  // Do not call create_e4_suspended: its artifact verifier accepts tiny reads.
  wchar_t exe[1024]{},cwd[1024]{},windows[1024]{};
  auto n=GetFinalPathNameByHandleW(image.handle,exe,1024,FILE_NAME_NORMALIZED|VOLUME_NAME_DOS);
  auto d=GetFinalPathNameByHandleW(dir.handle,cwd,1024,FILE_NAME_NORMALIZED|VOLUME_NAME_DOS);
  auto w=GetWindowsDirectoryW(windows,1024);
  if(!t.valid()||!n||n>=1024||!d||d>=1024||!w||w>=1024)return false;
  for(size_t i=0;i<2;++i) {
    DWORD flags=0;
    if(!GetHandleInformation(inherited[i],&flags)||!(flags&HANDLE_FLAG_INHERIT)||
       GetFileType(inherited[i])!=FILE_TYPE_PIPE)return false;
  }
  SIZE_T size=0;InitializeProcThreadAttributeList(nullptr,1,0,&size);
  if(!size||size>65536)return false;
  std::vector<uint8_t> storage(size);
  auto attributes=reinterpret_cast<PPROC_THREAD_ATTRIBUTE_LIST>(storage.data());
  if(!InitializeProcThreadAttributeList(attributes,1,0,&size))return false;
  bool configured=UpdateProcThreadAttribute(attributes,0,PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
      inherited,2*sizeof(HANDLE),nullptr,nullptr)!=FALSE;
  std::wstring command=L"l1-worker "+std::to_wstring(uintptr_t(inherited[0]))+L" "+
      std::to_wstring(uintptr_t(inherited[1]));
  std::wstring env=L"SystemRoot="+std::wstring(windows);env.push_back(0);
  env+=L"WINDIR="+std::wstring(windows);env.push_back(0);env.push_back(0);
  STARTUPINFOEXW si{};si.StartupInfo.cb=sizeof(si);si.lpAttributeList=attributes;
  bool ok=configured && CreateProcessW(exe,command.data(),nullptr,nullptr,TRUE,
      CREATE_SUSPENDED|CREATE_UNICODE_ENVIRONMENT|CREATE_NO_WINDOW|EXTENDED_STARTUPINFO_PRESENT,
      env.data(),cwd,&si.StartupInfo,&result)!=FALSE;
  DeleteProcThreadAttributeList(attributes);return ok;
}
} // namespace
bool measure_metadata(const WindowsObjectPin &p, bool directory,
                      std::string &sd, std::wstring &path) noexcept try {
  wchar_t name[1024]{}, fs[16]{};
  if (!pin_metadata(p,directory) || !security(p,sd) ||
      sd!=p.artifact_security_sha256) return false;
  const auto n=GetFinalPathNameByHandleW(p.handle,name,1024,FILE_NAME_NORMALIZED|VOLUME_NAME_DOS);
  if (!n || n>=1024 || std::wcsncmp(name,L"\\\\?\\C:\\",7) ||
      !GetVolumeInformationByHandleW(p.handle,nullptr,0,nullptr,nullptr,nullptr,fs,16) ||
      std::wcscmp(fs,L"NTFS")) return false;
  path.assign(name,n); return true;
} catch (...) { return false; }
bool measure_runtime(HANDLE process,RuntimeFacts &out) noexcept try {
  RuntimeFacts r;
  using Version=LONG(WINAPI *)(PRTL_OSVERSIONINFOW);
  auto module=GetModuleHandleW(L"ntdll.dll");
  auto raw=module?GetProcAddress(module,"RtlGetVersion"):nullptr;
  Version version=nullptr;static_assert(sizeof(raw)==sizeof(version));
  std::memcpy(&version,&raw,sizeof(raw));
  RTL_OSVERSIONINFOW v{};v.dwOSVersionInfoSize=sizeof(v);
  DWORD edition=0,revision=0,n=sizeof(revision);SYSTEM_INFO system{};
  GetNativeSystemInfo(&system);
  if(!version||version(&v)!=0 ||
      !GetProductInfo(v.dwMajorVersion,v.dwMinorVersion,0,0,&edition) ||
      RegGetValueW(HKEY_LOCAL_MACHINE,L"SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion",L"UBR",
        RRF_RT_REG_DWORD|RRF_SUBKEY_WOW6464KEY,nullptr,&revision,&n)!=ERROR_SUCCESS ||
      n!=sizeof(revision)||!token_user(process,r.sid) ||
      !inspect_exact_token(process,r.sid) || !created_at(process,r.creation_time))return false;
  r.pid=GetProcessId(process);if(!r.pid)return false;
  r.major=v.dwMajorVersion;r.minor=v.dwMinorVersion;r.build=v.dwBuildNumber;
  r.revision=revision;r.edition=edition;r.x64=system.wProcessorArchitecture==PROCESSOR_ARCHITECTURE_AMD64;
  USHORT machine=0,native=0;
  if(!IsWow64Process2(process,&machine,&native)||machine!=IMAGE_FILE_MACHINE_UNKNOWN||
      native!=IMAGE_FILE_MACHINE_AMD64||!r.x64)return false;
  r.primary_medium=r.non_elevated=true;r.account=sid_digest(r.sid);
  CanonicalHashBuilder os;os.put_str("SHIROHA_L1_R2_OS_V1");
  for(auto value:{r.major,r.minor,r.build,r.revision,r.edition})os.put_u32_le(value);
  os.put_bool(r.x64);r.os=os.finalize_hex();r.origin=r1::Origin::kWindowsApi;
  out=std::move(r);return true;
} catch(...) {return false;}
bool measure_artifact(const WindowsObjectPin &p,std::string &out,uint32_t &reads) noexcept try {
  if(!pin_metadata(p,false))return false;
  std::string sd;
  if(!security(p,sd)||sd!=p.artifact_security_sha256)return false;
  FileRead reader(p.handle);
  if(!bounded_hash(reader,out,reads)||!pin_metadata(p,false))return false;
  std::string after;return security(p,after)&&sd==after;
} catch(...) {return false;}
bool inspect_process_pin(const WindowsProcessPin &p,const std::wstring &sid) noexcept {
  uint64_t creation=0;
  return p.process && p.pid && GetProcessId(p.process)==p.pid &&
    created_at(p.process,creation)&&creation==p.creation &&
    inspect_exact_token(p.process,sid)&&inspect_e4_image(p.process,p.image);
}
bool bounded_dependencies(HANDLE process,const std::vector<WindowsObjectPin> &pins,
    const std::vector<std::string> &hashes) noexcept try {
  if(pins.empty()||pins.size()>kDependencies||pins.size()!=hashes.size())return false;
  HMODULE modules[kDependencies]{};DWORD n=0;
  if(!EnumProcessModulesEx(process,modules,sizeof(modules),&n,LIST_MODULES_ALL)||
      n!=pins.size()*sizeof(HMODULE))return false;
  std::array<bool,kDependencies> seen{};
  for(size_t i=0;i<pins.size();++i) {
    wchar_t path[1024]{};DWORD length=GetModuleFileNameExW(process,modules[i],path,1024);
    if(!length||length>=1024)return false;
    HANDLE file=CreateFileW(path,GENERIC_READ|READ_CONTROL,FILE_SHARE_READ,nullptr,
        OPEN_EXISTING,FILE_FLAG_OPEN_REPARSE_POINT,nullptr);
    if(file==INVALID_HANDLE_VALUE)return false;
    FILE_ID_INFO id{};bool found=false;
    if(GetFileInformationByHandleEx(file,FileIdInfo,&id,sizeof(id)))
      for(size_t j=0;j<pins.size();++j)if(!seen[j]&&identity(id)==identity(pins[j].identity)) {
        std::string h;uint32_t reads=0;
        found=measure_artifact(pins[j],h,reads)&&h==hashes[j];seen[j]=found;break;
      }
    bool closed=CloseHandle(file)!=FALSE;if(!found||!closed)return false;
  }
  return true;
} catch(...) {return false;}
namespace {
ImageObservation measure_image(const WindowsProcessPin &p,
                               const std::wstring &sid) {
  ImageObservation out;
  std::string hash;
  uint32_t reads = 0;
  if (!inspect_process_pin(p, sid) || !measure_artifact(p.image, hash, reads) ||
      !inspect_process_pin(p, sid))
    return out;
  out.origin = r1::Origin::kWindowsApi;
  out.status = r1::IoStatus::kOk;
  out.process_verified = true;
  out.object = identity(p.image.identity);
  out.sha256 = hash;
  // measure_artifact has already compared the actual Owner/DACL digest
  // both before and after the byte read against this pinned digest.
  out.security_sha256 = p.image.artifact_security_sha256;
  return out;
}
} // namespace
WindowsIdentity::WindowsIdentity(std::vector<WindowsPinSpec> p,
                                 std::array<WindowsProcessPin, 3> processes,
                                 std::vector<HANDLE> inherited, r1::Frozen f,
                                 Limits l)
    : pins_(std::move(p)), processes_(std::move(processes)),
      inherited_(std::move(inherited)), frozen_(std::move(f)),
      limits_(std::move(l)) {}
r1::Measurement WindowsIdentity::measure() {
  r1::Measurement m;
  if (++measurements_ > 5 || pins_.empty() || pins_.size() > kPins ||
      inherited_.size() > 8 ||
      frozen_.manifest.build.origin != r1::Origin::kIndependentBuild)
    return m;
  RuntimeFacts actual;
  if(!measure_runtime(GetCurrentProcess(),actual))return m;
  wchar_t name[256]{};DWORD n=256;
  if(!GetComputerNameExW(ComputerNamePhysicalDnsFullyQualified,name,&n)||!n||n>=256)return m;
  CanonicalHashBuilder device;device.put_str("SHIROHA_L1_R2_DEVICE_V1");
  for(DWORD i=0;i<n;++i)device.put_u16_le(uint16_t(name[i]));
  m.device_sha256=device.finalize_hex();m.os_sha256=actual.os;
  m.token_sid=actual.sid;m.account_sha256=actual.account;
  m.primary_medium=actual.primary_medium;m.non_elevated=actual.non_elevated;m.minimal_privileges=true;
  for(const auto &p:pins_) {
    if(!safe_id(p.id)||!safe_id(p.owner)||p.chain.empty()||p.chain.size()>kParents||
       !inspect_e4_parent_chain(p.chain)||!same(p.chain.back(),p.parent)||
       !pin_metadata(p.object,p.directory)||!child_of(p.object,p.parent))return {};
    r1::Pin observed;observed.id=p.id;observed.owner=p.owner;
    observed.object=identity(p.object.identity);observed.parent=identity(p.parent.identity);
    if(!security(p.object,observed.security_sha256))return {};
    if(p.artifact) {uint32_t reads=0;if(!measure_artifact(p.object,observed.bytes_sha256,reads))return {};}
    else {CanonicalHashBuilder h;h.put_str("SHIROHA_L1_R2_METADATA_ONLY_V1");
      h.put_u64_le(observed.object.volume_serial);h.put_bytes(observed.object.file_id.data(),16);
      observed.bytes_sha256=h.finalize_hex();}
    m.pins.push_back(observed);
  }
  // Artifact hashes are measured from pins independently from BuildEvidence.
  // This inventory must contain the three exact executable pins.
  if (m.pins != frozen_.manifest.pins)
    return {};
  std::array<ImageObservation, 3> images;
  for (size_t i = 0; i < 3; ++i)
    images[i] = measure_image(processes_[i], actual.sid);
  if (!match_images(frozen_, limits_, images, 3))
    return {};
  for(size_t i=0;i<inherited_.size();++i) {
    DWORD flags=0;
    if(!GetHandleInformation(inherited_[i],&flags)||!(flags&HANDLE_FLAG_INHERIT)||
       GetFileType(inherited_[i])!=FILE_TYPE_PIPE)return {};
    for(size_t j=0;j<i;++j)if(inherited_[i]==inherited_[j])return {};
  }
  m.origin = r1::Origin::kWindowsApi;
  m.build = frozen_.manifest.build;
  return m;
}
WindowsPersistence::WindowsPersistence(WindowsObjectPin p,std::vector<WindowsObjectPin> c,Output o)
    :parent_(std::move(p)),chain_(std::move(c)),output_(o) {}
bool WindowsPersistence::open_new() noexcept try {
  if(attempted_)return false;attempted_=true;
  if(chain_.empty()||chain_.size()>kParents||!same(chain_.back(),parent_)||
     !inspect_e4_parent_chain(chain_)||!inspect_e4_pin(parent_,true,0))return false;
  const wchar_t *names[]={L"custody.r2",L"evidence-controller.r2",L"evidence-custodian.r2"};
  auto index=unsigned(output_);if(index>2)return false;
  auto module=GetModuleHandleW(L"ntdll.dll");auto raw=module?GetProcAddress(module,"NtCreateFile"):nullptr;
  decltype(&NtCreateFile) create=nullptr;static_assert(sizeof(create)==sizeof(raw));
  std::memcpy(&create,&raw,sizeof(raw));if(!create)return false;
  PSID sid=nullptr;if(!ConvertStringSidToSidW(parent_.owner_sid.c_str(),&sid))return false;
  SECURITY_DESCRIPTOR sd{};alignas(ACL) uint8_t buffer[512]{};auto acl=reinterpret_cast<PACL>(buffer);
  bool secured=InitializeSecurityDescriptor(&sd,SECURITY_DESCRIPTOR_REVISION)&&
      SetSecurityDescriptorOwner(&sd,sid,FALSE)&&InitializeAcl(acl,sizeof(buffer),ACL_REVISION)&&
      AddAccessAllowedAceEx(acl,ACL_REVISION,0,FILE_ALL_ACCESS,sid)&&
      SetSecurityDescriptorDacl(&sd,TRUE,acl,FALSE)&&
      SetSecurityDescriptorControl(&sd,SE_DACL_PROTECTED,SE_DACL_PROTECTED);
  UNICODE_STRING name{};name.Buffer=const_cast<PWSTR>(names[index]);
  name.Length=USHORT(std::wcslen(names[index])*sizeof(wchar_t));name.MaximumLength=name.Length;
  OBJECT_ATTRIBUTES a{};a.Length=sizeof(a);a.RootDirectory=parent_.handle;a.ObjectName=&name;
  a.Attributes=OBJ_CASE_INSENSITIVE|OBJ_DONT_REPARSE;a.SecurityDescriptor=&sd;
  IO_STATUS_BLOCK io{};HANDLE h=INVALID_HANDLE_VALUE;
  bool ok=secured && create(&h,GENERIC_READ|GENERIC_WRITE|READ_CONTROL|SYNCHRONIZE,&a,&io,nullptr,
      FILE_ATTRIBUTE_NORMAL,FILE_SHARE_READ,FILE_CREATE,
      FILE_NON_DIRECTORY_FILE|FILE_OPEN_REPARSE_POINT|FILE_SYNCHRONOUS_IO_NONALERT,
      nullptr,0)==0 && io.Status==0 && io.Information==FILE_CREATED;
  bool freed=LocalFree(sid)==nullptr;
  // Even ambiguous creation retains the returned handle; never retry/clean.
  file_.handle=h;file_.owner_sid=parent_.owner_sid;
  if(!ok||!freed||!GetFileInformationByHandleEx(h,FileIdInfo,&file_.identity,sizeof(file_.identity))) {
    failed_=true;return false;
  }
  return inspect_destination();
} catch(...) {failed_=true;return false;}
bool WindowsPersistence::inspect_destination() {
  return !failed_&&!closed_&&attempted_&&inspect_e4_pin(parent_,true,0)&&
    inspect_e4_pin(file_,false,length_)&&child_of(file_,parent_);
}
WriteStatus WindowsPersistence::write(const uint8_t *b,size_t n,size_t &done) {
  done=0;const uint32_t max=output_==Output::custody?16:kPolls+32;
  if(failed_||pending_||++writes_>max||!b||
      n!=(output_==Output::custody?512:kRecordBytes)||!inspect_destination())return WriteStatus::unknown;
  pending_=true;DWORD count=0;
  if(!WriteFile(file_.handle,b,DWORD(n),&count,nullptr)||count!=n) {
    failed_=true;done=count;return WriteStatus::unknown;
  }
  done=count;length_+=n;return WriteStatus::ok;
}
WriteStatus WindowsPersistence::flush() {
  if(failed_||!pending_||++flushes_>writes_||!FlushFileBuffers(file_.handle)) {
    failed_=true;return WriteStatus::unknown;
  }
  pending_=false;return WriteStatus::ok;
}
bool WindowsPersistence::close_once() noexcept {
  if(closed_)return false;closed_=true;
  return file_.handle && file_.handle!=INVALID_HANDLE_VALUE && CloseHandle(file_.handle)!=FALSE;
}
WindowsProof::WindowsProof(WindowsObjectPin p,std::vector<WindowsObjectPin> c,
    WindowsObjectPin r,WindowsObjectPin g,WindowsObjectPin j)
    :parent_(std::move(p)),receipt_(std::move(r)),grant_(std::move(g)),journal_(std::move(j)),chain_(std::move(c)) {}
bool WindowsProof::read_once(Consumption &out) {
  if(attempted_)return false;attempted_=true;
  if(chain_.empty()||chain_.size()>kParents||!same(chain_.back(),parent_)||
     !inspect_e4_parent_chain(chain_))return false;
  for(auto p:{&receipt_,&grant_,&journal_})if(!child_of(*p,parent_))return false;
  Consumption c;
  if(!read_exact(receipt_,c.receipt.data(),256)||!read_exact(grant_,&c.marker,1)||
      !read_exact(journal_,c.journal.data(),128))return false;
  c.pins={identity(parent_.identity),identity(receipt_.identity),identity(grant_.identity)};
  c.issued={e4::get(c.receipt.data()+8,8),e4::get(c.receipt.data()+16,8),e4::get(c.receipt.data()+24,8),true};
  if(!read_e4_clock(c.now,c.issued.session))return false;
  c.independently_pinned=true;out=c;return true;
}
WindowsControl::WindowsControl(HANDLE r,HANDLE w,WindowsProcessPin p,std::wstring sid,Limits l,uint64_t origin)
    :read_(r),write_(w),peer_(std::move(p)),sid_(std::move(sid)),limits_(std::move(l)),origin_(origin) {}
bool WindowsControl::peer_checked() {
  if(failed_)return false;if(checked_)return true;
  checked_=limits_.valid() && read_!=write_ && GetFileType(read_)==FILE_TYPE_PIPE &&
      GetFileType(write_)==FILE_TYPE_PIPE && inspect_process_pin(peer_,sid_);
  failed_=!checked_;return checked_;
}
bool WindowsControl::take(Packet &p) {
  const uint32_t max=8*limits_.polls+64;
  while(!failed_ && ++polls_<=max) {
    const auto now=GetTickCount64();
    if(now<origin_||now-origin_>=30000)break;
    DWORD available=0;
    if(!PeekNamedPipe(read_,nullptr,0,nullptr,&available,nullptr))break;
    if(available>=p.size()) {
      DWORD n=0;
      if(++reads_>max||!ReadFile(read_,p.data(),DWORD(p.size()),&n,nullptr)||n!=p.size())break;
      return true;
    }
    Sleep(limits_.poll_ms);
  }
  failed_=true;return false;
}
bool WindowsControl::put(const Packet &p) {
  DWORD n=0;
  if(failed_||++writes_>8*limits_.polls+64||
     !WriteFile(write_,p.data(),DWORD(p.size()),&n,nullptr)||n!=p.size())return failed_=true,false;
  return true;
}
bool WindowsControl::exchange(const Packet &in,Packet &out) {return peer_checked()&&put(in)&&take(out);}
bool WindowsControl::serve_once(Endpoint &e) {
  // A transport failure is not a negative reply. Report it to the Custodian
  // exactly once and let the caller stop serving; never retry.
  Packet in{},out{};
  if(!peer_checked()||!take(in)){e.lost();return false;}
  if(!e.dispatch(in,out))return false;
  if(!put(out)){e.lost();return false;}
  return true;
}
WindowsWorkerLink::WindowsWorkerLink(HANDLE r,HANDLE w,uint32_t p,uint32_t ms,uint64_t origin)
    :read_(r),write_(w),poll_ms_(ms),origin_(origin) {budget_.limit=p;}
bool WindowsWorkerLink::send(const e4::Frame &f) {
  if(budget_.failed||budget_.writes>=44)return false;
  DWORD n=0;bool ok=WriteFile(write_,f.data(),DWORD(f.size()),&n,nullptr)!=FALSE;
  return budget_.write(f.size(),ok?n:0,44);
}
bool WindowsWorkerLink::poll_control(e4::Frame &f,bool &available) {
  available=false;
  auto now=GetTickCount64();
  if(!budget_.poll()||now<origin_||now-origin_>=30000)return false;
  DWORD count=0;if(!PeekNamedPipe(read_,nullptr,0,nullptr,&count,nullptr))return budget_.failed=true,false;
  if(!count)return true;
  DWORD n=0;size_t request=(std::min)(size_t(count),f.size()-used_);
  bool ok=ReadFile(read_,partial_.data()+used_,DWORD(request),&n,nullptr)!=FALSE;
  if(!budget_.read(request,ok?n:0,!ok&&GetLastError()==ERROR_BROKEN_PIPE))return false;
  used_+=n;if(used_==f.size()){f=partial_;used_=0;available=true;}return true;
}
bool WindowsWorkerLink::receive(e4::Frame &f) {
  if(!poll_ms_||poll_ms_>50)return false;
  while(!budget_.failed){bool available=false;if(!poll_control(f,available))return false;
    if(available)return true;Sleep(poll_ms_);}return false;
}
bool WindowsWorkerLink::checkpoint(L1CryptoLedger &l) {
  ResourceSample s;bool exit=false,normal=false;
  return ++samples_<=18 && observe_process(GetCurrentProcess(),s,exit,normal)&&!exit&&
    l.resources(s.peak_working_set,s.peak_commit,s.handles);
}
bool bounded_approval(const e4::ApprovalPromptModel &p,e4::ApprovalUiResponse &r,const Limits &l) noexcept try {
  r={};if(!l.valid()||p.summary.size()>16384)return false;
  // One modeless dialog. All dispatched messages share one event/time budget;
  // no unbounded first MessageBox or modal hidden message pump. The summary is
  // a scrollable read-only edit so the full target text is reviewable.
  struct Data {const e4::ApprovalPromptModel *p;e4::ApprovalUiResponse *r;UiBudget budget;
    bool done=false,reviewed=false;HWND summary=nullptr;bool controls_ok=false;};
  const auto origin=GetTickCount64();
  Data data{&p,&r,{origin,l.approval_ms,origin,l.ui_events,0,false},false,false};
  alignas(DWORD) uint8_t raw[128]{};auto dialog=reinterpret_cast<DLGTEMPLATE *>(raw);
  dialog->style=WS_POPUP|WS_CAPTION|WS_SYSMENU;dialog->cx=420;dialog->cy=360;
  auto proc=+[](HWND window,UINT msg,WPARAM wp,LPARAM lp)->INT_PTR {
    if(msg==WM_INITDIALOG) {
      SetWindowLongPtrW(window,DWLP_USER,lp);
      auto d=reinterpret_cast<Data *>(lp);
      std::wstring summary(d->p->summary.begin(),d->p->summary.end());
      d->summary=CreateWindowExW(WS_EX_CLIENTEDGE,L"EDIT",summary.c_str(),
          WS_CHILD|WS_VISIBLE|WS_VSCROLL|ES_MULTILINE|ES_READONLY,
          4,4,410,250,window,reinterpret_cast<HMENU>(100),nullptr,nullptr);
      auto check=CreateWindowExW(0,L"BUTTON",L"I reviewed this target",WS_CHILD|WS_VISIBLE|BS_AUTOCHECKBOX,
          4,260,300,24,window,reinterpret_cast<HMENU>(102),nullptr,nullptr);
      auto edit=CreateWindowExW(0,L"EDIT",L"",WS_CHILD|WS_VISIBLE|WS_BORDER,4,290,180,24,
          window,reinterpret_cast<HMENU>(101),nullptr,nullptr);
      auto approve=CreateWindowExW(0,L"BUTTON",L"Approve once",WS_CHILD|WS_VISIBLE,210,290,150,24,
          window,reinterpret_cast<HMENU>(IDOK),nullptr,nullptr);
      const int length=d->summary?GetWindowTextLengthW(d->summary):0;
      // The summary edit may expand LF to CRLF; shorter/empty text is a failure.
      d->controls_ok=approval_display_ok(
          d->summary!=nullptr,check!=nullptr,edit!=nullptr,approve!=nullptr,
          length>0?size_t(length):0,summary.size());
      if(!d->controls_ok){d->r->cancelled=true;d->done=true;return TRUE;}
      SendMessageW(edit,EM_SETLIMITTEXT,6,0);return TRUE;
    }
    auto d=reinterpret_cast<Data *>(GetWindowLongPtrW(window,DWLP_USER));if(!d)return FALSE;
    if(!d->budget.event(GetTickCount64())){d->r->timed_out=true;d->done=true;return TRUE;}
    if(msg==WM_CLOSE){d->r->cancelled=true;d->done=true;return TRUE;}
    if(msg==WM_COMMAND&&LOWORD(wp)==IDOK) {
      if(!d->controls_ok){d->r->cancelled=true;d->done=true;return TRUE;}
      wchar_t input[8]{};GetDlgItemTextW(window,101,input,8);
      std::string typed;for(wchar_t c:input){if(!c)break;if(c>127){d->done=true;return TRUE;}typed.push_back(char(c));}
      bool checked=SendDlgItemMessageW(window,102,BM_GETCHECK,0,0)==BST_CHECKED;
      d->r->completed=d->r->checked=checked&&typed==d->p->suffix;
      d->r->suffix=typed;
      // The hash is evidence only after every required control exists, the
      // summary text is present, and the dialog is visible.
      if(d->r->completed)d->r->displayed_hash=d->p->target_hash;
      d->done=true;return TRUE;
    }
    return FALSE;
  };
  HWND window=CreateDialogIndirectParamW(GetModuleHandleW(nullptr),dialog,nullptr,proc,reinterpret_cast<LPARAM>(&data));
  if(!window)return false;ShowWindow(window,SW_SHOW);
  // A created control that is not actually visible cannot evidence a display.
  if(!data.controls_ok||!data.summary||!IsWindowVisible(data.summary)) {
    DestroyWindow(window);return false;
  }
  uint32_t polls=0;
  while(!data.done&&++polls<=kPolls) {
    if(!data.budget.event(GetTickCount64()))break;
    MSG msg{};
    if(PeekMessageW(&msg,nullptr,0,0,PM_REMOVE)) {
      if(msg.message==WM_QUIT)break;
      TranslateMessage(&msg);DispatchMessageW(&msg);
    } else Sleep(50);
  }
  bool destroyed=DestroyWindow(window)!=FALSE;
  return destroyed&&data.done&&!data.budget.failed&&r.completed&&r.checked;
} catch(...) {return false;}
WindowsOwner::WindowsOwner(r1::Frozen f,Limits l,WindowsObjectPin d,WindowsObjectPin i,
    std::vector<WindowsObjectPin> deps,std::vector<std::string> hashes,
    std::array<WindowsProcessPin,2> hosts,uint64_t session)
    :frozen_(std::move(f)),limits_(std::move(l)),directory_(std::move(d)),image_(std::move(i)),
      dependencies_(std::move(deps)),hashes_(std::move(hashes)),hosts_(std::move(hosts)),session_(session) {}
std::array<ImageObservation, 3> WindowsOwner::measure_hosts() try {
  // Only one complete byte measurement of each host EXE per Batch. Never
  // refresh a failed or already captured snapshot: doing so would reset the
  // per-artifact 256 ReadFile budget and allow a second admission attempt.
  if (hosts_measurement_attempted_) return host_images_;
  hosts_measurement_attempted_ = true;
  if (accepted_ || stopped_) return {};
  for (size_t i = 0; i < 2; ++i)
    host_images_[i] = measure_image(hosts_[i], frozen_.target.sid);
  if (!match_images(frozen_, limits_, host_images_, 2)) {
    host_images_ = {};
    stopped_ = true;
  }
  return host_images_;
} catch (...) {
  host_images_ = {};
  stopped_ = true;
  return {};
}
bool WindowsOwner::revalidate_hosts_no_read(
    const std::array<ImageObservation, 3> &images) const {
  // Recheck live process + File ID + security descriptor without reading
  // executable bytes again. Borrowed image pins continue to deny writes
  // and deletion between the original measurement and custody acceptance.
  for (size_t i = 0; i < 2; ++i) {
    std::string actual_security;
    if (!inspect_process_pin(hosts_[i], frozen_.target.sid) ||
        !pin_metadata(hosts_[i].image, false) ||
        !security(hosts_[i].image, actual_security) ||
        actual_security != images[i].security_sha256)
      return false;
  }
  return true;
}
r1::CustodyReceipt WindowsOwner::accept_intent(const r1::Frozen &f) try {
  if (accepted_ || stopped_)
    return {};
  const auto images = measure_hosts(); // cached after Custodian precheck
  stopped_ = true; // failed identity never retries or accepts a later Batch
  if (f.hash() != frozen_.hash() ||
      !match_images(frozen_, limits_, images, 2) ||
      !revalidate_hosts_no_read(images))
    return {};
  accepted_ = true;
  stopped_ = false;
  // Persistence is still owned by the Custodian's separately flushed journal.
  return {r1::Origin::kWindowsApi,r1::IoStatus::kOk,f.manifest.custody_owner,
      f.hash(),{},true,false,{}};
} catch (...) {
  stopped_ = true;
  return {};
}
bool WindowsOwner::create_suspended() {
  std::string h;uint32_t reads=0;
  if(!measure_artifact(image_,h,reads)||h!=frozen_.target.grant.exe_sha256||
      !inspect_e4_pin(directory_,true,0)||!create_e4_pipe_pair(pipes_))return false;
  origin_=GetTickCount64();
  HANDLE inherited[]={pipes_[2],pipes_[1]};auto t=frozen_.target.grant;t.user_approved=true;
  custody_.created=bounded_create(t,image_,directory_,inherited,custody_.process);
  return custody_.created;
}
e4::WorkerStart WindowsOwner::create() {
  e4::WorkerStart s;
  if(!accepted_||attempted_||stopped_)return s;attempted_=true;
  if(!create_suspended()){s.creation_unknown=true;return s;}
  s.created=true;s.pid=custody_.process.dwProcessId;
  custody_.handles_checked=close_pipe(1)&&close_pipe(2);return s;
}
r1::ProcessIdentity WindowsOwner::process_identity() {
  RuntimeFacts facts;
  if(!custody_.created||!measure_runtime(custody_.process.hProcess,facts)||
      facts.sid!=frozen_.target.sid||!inspect_e4_image(custody_.process.hProcess,image_))return {};
  return {facts.pid,facts.creation_time,frozen_.target.grant.exe_sha256,facts.account,
      frozen_.hash(),frozen_.manifest.custody_owner,facts.primary_medium,facts.non_elevated};
}
r1::CustodyReceipt WindowsOwner::acknowledge_identity(const r1::ProcessIdentity &p) {
  if(ack_||p.hash()!=process_identity().hash()||!custody_.handles_checked)return {};
  ack_=true;return {r1::Origin::kWindowsApi,r1::IoStatus::kOk,frozen_.manifest.custody_owner,
      frozen_.hash(),{},true,true,p.hash()};
}
bool WindowsOwner::token(){return custody_.token_checked=inspect_exact_token(custody_.process.hProcess,frozen_.target.sid);}
bool WindowsOwner::image(){return custody_.image_checked=inspect_e4_image(custody_.process.hProcess,image_);}
bool WindowsOwner::dependencies() {
  // Before Resume, pin/hash inventory only; loaded closure after HELLO.
  if(dependencies_.empty()||dependencies_.size()>kDependencies||dependencies_.size()!=hashes_.size())return false;
  if(custody_.resume_attempted)return bounded_dependencies(custody_.process.hProcess,dependencies_,hashes_);
  for(size_t i=0;i<dependencies_.size();++i){std::string h;uint32_t n=0;
    if(!measure_artifact(dependencies_[i],h,n)||h!=hashes_[i])return false;}
  return custody_.dependencies_checked=true;
}
bool WindowsOwner::handles(){return custody_.handles_checked;}
bool WindowsOwner::resume(bool &known){known=false;
  if(stopped_||!ack_)return false;bool ok=resume_e4_once(custody_);known=!custody_.resume_unknown;return ok;}
e4::ClockReading WindowsOwner::read_clock(){e4::ClockReading r;read_e4_clock(r,session_);return r;}
bool WindowsOwner::take(e4::Frame &f,bool &available) {
  available=false;
  if(stopped_||++polls_>limits_.polls)return false;
  auto now=GetTickCount64();if(now<origin_||now-origin_>=30000)return false;
  DWORD count=0;if(!PeekNamedPipe(pipes_[0],nullptr,0,nullptr,&count,nullptr))return false;
  if(!count)return true;
  size_t request=(std::min)(size_t(count),f.size()-used_);DWORD n=0;
  if(++reads_>limits_.polls||!ReadFile(pipes_[0],partial_.data()+used_,DWORD(request),&n,nullptr)||
      !n||n>request)return false;
  used_+=n;if(used_==f.size()){f=partial_;used_=0;available=true;}return true;
}
bool WindowsOwner::hello(){bool available=false;
  while(!stopped_&&polls_<limits_.polls){if(!take(hello_,available))return false;
    if(available){hello_pending_=true;return true;}Sleep(limits_.poll_ms);}return false;}
bool WindowsOwner::next(e4::Frame &f,bool &available){if(hello_pending_){hello_pending_=false;f=hello_;available=true;return true;}
  return take(f,available);}
bool WindowsOwner::send(const e4::Frame &f){DWORD n=0;
  return !stopped_&&++sends_<=3&&WriteFile(pipes_[3],f.data(),DWORD(f.size()),&n,nullptr)&&n==f.size();}
bool WindowsOwner::sample_three(std::array<ResourceSample,3> &s){
  bool exited=false,normal=false;
  for(size_t i=0;i<2;++i)if(!observe_process(hosts_[i].process,s[i],exited,normal)||exited)return false;
  if(custody_.created) {
    if(!observe_process(custody_.process.hProcess,s[2],exited,normal))return false;
  } else {s[2].observed_at_ms=GetTickCount64();}
  return true;
}
e5::Observation WindowsOwner::observe(){e5::Observation o;bool ce=false,normal=false;
  o.healthy=observe_process(hosts_[0].process,o.controller,ce,normal)&&!ce;
  if(custody_.created)o.healthy=observe_process(custody_.process.hProcess,o.worker,o.exited,o.normal_exit)&&o.healthy;
  exit_=o.healthy&&o.exited;return o;}
bool WindowsOwner::close_observed_exit(){return exit_&&close_e4_observed_exit(custody_);}
bool WindowsOwner::close_pipe(size_t i){if(pipe_closed_[i])return false;pipe_closed_[i]=true;
  if(!pipes_[i])return true;bool ok=CloseHandle(pipes_[i])!=FALSE;if(ok)pipes_[i]=nullptr;return ok;}
bool WindowsOwner::close_owned_io(){if(io_closed_)return false;io_closed_=true;bool ok=true;
  for(size_t i=0;i<4;++i)if(!pipe_closed_[i])ok=close_pipe(i)&&ok;return ok;}
bool WindowsOwner::approve(const e4::ApprovalPromptModel &,e4::ApprovalUiResponse &){return false;}
} // namespace shiroha_l1_crypto::r2
