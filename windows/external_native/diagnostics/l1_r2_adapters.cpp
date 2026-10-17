#include "diagnostics/l1_r2_adapters.h"
#include <cstring>

namespace shiroha_l1_crypto::r2 {
namespace {
std::string hash(const uint8_t *p, size_t n) {
  auto d = e4::digest(p, n);
  return encode_hex_bytes(d.data(), d.size());
}
std::string text_hash(const std::string &s) {
  return hash(reinterpret_cast<const uint8_t *>(s.data()), s.size());
}
void digest_at(uint8_t *p, const std::string &s) {
  if (!s.empty()) decode_hex_bytes(s, p, 32);
}
std::string digest_at(const uint8_t *p) { return encode_hex_bytes(p, 32); }
Packet packet(Op op, uint32_t seq, const r1::Frozen &f,
              const std::string &channel) {
  Packet p{};
  e4::put(p.data(), 0x32434853, 4);
  e4::put(p.data()+4, 1, 2);
  e4::put(p.data()+6, unsigned(op), 2);
  e4::put(p.data()+8, seq, 4);
  digest_at(p.data()+16, f.hash());
  digest_at(p.data()+48, text_hash(f.target.grant.batch_id));
  digest_at(p.data()+80, channel);
  return p;
}
void seal(Packet &p) { digest_at(p.data()+480, hash(p.data(),480)); }
bool valid(const Packet &p, const Packet &expected) {
  return std::equal(p.begin(),p.begin()+112,expected.begin()) &&
         e4::zero(p.data()+468,12) &&
         digest_at(p.data()+480) == hash(p.data(),480);
}
void sample_encode(uint8_t *p, const ResourceSample &s) {
  e4::put(p,s.observed_at_ms,8); e4::put(p+8,s.peak_working_set,8);
  e4::put(p+16,s.peak_commit,8); e4::put(p+24,s.handles,4);
}
ResourceSample sample_decode(const uint8_t *p) {
  return {e4::get(p,8),e4::get(p+8,8),e4::get(p+16,8),
          uint32_t(e4::get(p+24,4)),0};
}
bool transfer(PersistencePort &p, const uint8_t *bytes, size_t n,
              uint32_t &writes, uint32_t &flushes) {
  if (!p.inspect_destination()) return false;
  size_t done = 0;
  ++writes; // consumed before ambiguous side effect
  if (p.write(bytes,n,done) != WriteStatus::ok || done != n) return false;
  ++flushes;
  return p.flush() == WriteStatus::ok && p.inspect_destination();
}
} // namespace
bool Limits::valid() const {
  if (!hex_digest(custodian_sha256,64) || !hex_digest(channel_sha256,64) ||
      !polls || polls > kPolls || !poll_ms || poll_ms > 50 ||
      !ui_events || ui_events > kUiEvents || !approval_ms || approval_ms > 60000 ||
      !handoff_ms || handoff_ms > 30000) return false;
  for (const auto &p : process) if (!p.valid()) return false;
  return true;
}
std::string Limits::hash() const {
  CanonicalHashBuilder h;
  h.put_str("SHIROHA_L1_R2_LIMITS_V1");
  h.put_str(custodian_sha256); h.put_str(channel_sha256);
  for (const auto &p:process) {
    h.put_u64_le(p.working); h.put_u64_le(p.commit); h.put_u32_le(p.handles);
  }
  for (auto p:{polls,poll_ms,ui_events}) h.put_u32_le(p);
  h.put_u64_le(approval_ms); h.put_u64_le(handoff_ms);
  return h.finalize_hex();
}
bool bounded_hash(ReadPort &p, std::string &out, uint32_t &reads) {
  out.clear(); reads = 0;
  uint64_t n = 0;
  if (!p.size(n) || !n || n > kArtifactBytes || !p.rewind()) return false;
  std::vector<uint8_t> bytes(size_t(n),0);
  for (size_t at=0;at<bytes.size();) {
    const size_t requested = (std::min)(kReadBlock,bytes.size()-at);
    size_t returned=0;
    if (++reads > kArtifactBytes/kReadBlock ||
        !p.read(bytes.data()+at,requested,returned) || returned != requested)
      return false;
    at += returned;
  }
  uint64_t after=0;
  if (!p.size(after) || after != n) return false;
  out = hash(bytes.data(),bytes.size());
  return true;
}
PersistentEvidence::PersistentEvidence(PersistencePort &p,std::string b,
    std::string t,std::string o,uint32_t max)
    :port_(p),batch_(std::move(b)),target_(std::move(t)),owner_(std::move(o)),max_(max) {}
r1::SinkReceipt PersistentEvidence::preserve(const r1::Record &r) {
  r1::SinkReceipt ack;
  if (failed_) return ack;
  failed_=true; // every exception/partial/unknown burns this stream
  const auto rh=r.hash();
  if (!safe_id(owner_) || !max_ || max_>kPolls+32 || sequence_>=max_ ||
      r.sequence!=sequence_+1 || r.previous!=previous_ || r.batch!=batch_ ||
      r.target!=target_ || rh.empty()) return ack;
  std::array<uint8_t,kRecordBytes> b{};
  size_t at=0;
  auto u64=[&](uint64_t n){e4::put(b.data()+at,n,8);at+=8;};
  auto str=[&](const std::string &s){u64(s.size());
    std::copy(s.begin(),s.end(),b.begin()+at);at+=s.size();};
  u64(0x32454853);u64(1); // fixed OFFLINE record version, no LOCAL-L1 claim
  for (auto p:{&owner_,&r.batch,&r.target,&r.manifest,&r.previous,&rh,&r.reviewer,
              &r.verifier,&r.review_sha256,&r.verification_sha256,
              &r.process_identity_sha256}) str(*p);
  for (uint64_t n:{uint64_t(r.sequence),uint64_t(r.stage),uint64_t(r.first_failure),
      uint64_t(r.pid),r.creation_time,r.utc_ms,r.mono_ms,r.launch_attempt_ms,
      uint64_t(r.first_stop),uint64_t(r.sample_count),uint64_t(r.security),
      uint64_t(r.stability)}) u64(n);
  auto counts=[&](const CallCounts &c){
    for (auto n:{c.attempted,c.returned,c.accepted,c.settled,c.unknown,c.returned_failure}) u64(n);
  };
  for (const auto &c:r.abi) counts(c);
  for (const auto &c:r.native) counts(c);
  for (const auto &s:r.samples) {sample_encode(b.data()+at,s);at+=32;}
  sample_encode(b.data()+at,r.controller_peak);at+=32;
  for (bool f:{r.approved,r.consumed,r.created,r.resumed,r.creation_unknown,
      r.deadline_exceeded,r.ipc_complete,r.custody_accepted,r.custody_acknowledged,
      r.exited,r.handles_closed,r.recovery_required}) u64(f);
  if (at> b.size()-32) return ack;
  digest_at(b.data()+b.size()-32,hash(b.data(),b.size()-32));
  if (!transfer(port_,b.data(),b.size(),writes_,flushes_)) return ack;
  ++sequence_; previous_=rh; failed_=false;
  return {port_.origin(),r1::IoStatus::kOk,sequence_,rh};
}
CustodyJournal::CustodyJournal(PersistencePort &p,std::string b,std::string t,std::string o)
    :port_(p),batch_(std::move(b)),target_(std::move(t)),owner_(std::move(o)) {}
bool CustodyJournal::append(State state,const r1::ProcessIdentity &process) {
  if (failed_) return false;
  failed_=true;
  if (++count_>16 || !safe_id(batch_) || !safe_id(owner_) || !hex_digest(target_,64)) return false;
  std::array<uint8_t,512> b{};
  e4::put(b.data(),0x324a4353,4);e4::put(b.data()+4,1,4);
  e4::put(b.data()+8,count_,4);e4::put(b.data()+12,unsigned(state),4);
  digest_at(b.data()+16,target_);digest_at(b.data()+48,text_hash(batch_));
  digest_at(b.data()+80,text_hash(owner_));digest_at(b.data()+112,previous_);
  if (process.pid) digest_at(b.data()+144,process.hash());
  auto h=hash(b.data(),480);digest_at(b.data()+480,h);
  uint32_t w=0,f=0;
  if (!transfer(port_,b.data(),b.size(),w,f)) return false;
  previous_=h;failed_=false;return true;
}
Custodian::Custodian(r1::Frozen f,Limits l,OwnerPort &o,ProofPort &p,CustodyJournal &j)
    :frozen_(std::move(f)),limits_(std::move(l)),owner_(o),proof_(p),journal_(j) {}
bool Custodian::unknown() {state_=State::unknown;stopped_=true;return false;}
bool Custodian::persist(State s) {
  if (state_==State::unknown || !journal_.append(s,identity_)) return unknown();
  state_=s;return true;
}
r1::CustodyReceipt Custodian::receipt(bool handles) {
  return {r1::Origin::kFake,r1::IoStatus::kOk,frozen_.manifest.custody_owner,
    frozen_.hash(),journal_.last(),true,handles,handles?identity_.hash():std::string{}};
}
r1::CustodyReceipt Custodian::accept_intent(const r1::Frozen &f) {
  if (state_!=State::preapproved || accepted_ || !f.valid() ||
      f.hash()!=frozen_.hash() || !limits_.valid() ||
      f.manifest.r2_sha256!=limits_.hash() || f.manifest.max_pumps!=limits_.polls ||
      limits_.process[0].working!=f.target.scope.controller_working ||
      limits_.process[0].commit!=f.target.scope.controller_commit ||
      limits_.process[0].handles!=f.target.scope.controller_handles ||
      limits_.process[2].working!=f.target.grant.working_set_bytes ||
      limits_.process[2].commit!=f.target.grant.commit_bytes ||
      limits_.process[2].handles!=f.target.grant.handles) {unknown();return {};}
  accepted_=true;
  const auto a=owner_.accept_intent(f);
  if (a.status!=r1::IoStatus::kOk || !a.creator_is_independent ||
      a.target_sha256!=f.hash() || a.owner!=f.manifest.custody_owner ||
      !persist(State::ready) || !persist(State::accepted)) {unknown();return {};}
  return receipt(false);
}
e4::ClockReading Custodian::read_clock() {
  if (++clocks_>4*limits_.polls+32) {unknown();return {};}
  return owner_.read_clock();
}
bool Custodian::proof() {
  Consumption c;
  if (!proof_.read_once(c) || !c.independently_pinned || c.marker!=2 ||
      !c.pins.valid() || !e4::valid_journal(c.journal) || c.journal[6]!=3)
    return unknown();
  e4::ApprovalPromptModel p;
  std::string objects;
  if (!e4::prompt(frozen_.target.grant,frozen_.target.sid,p) ||
      !e4::valid_receipt(c.receipt,p,c.issued) ||
      !compute_object_identity_sha256(frozen_.hash(),c.pins,
          frozen_.target.grant.account_identity_sha256,objects) ||
      digest_at(c.journal.data()+32)!=frozen_.hash() ||
      digest_at(c.journal.data()+64)!=objects ||
      e4::get(c.journal.data()+8,8)!=c.issued.session ||
      !clock_.accept(c.issued) || !clock_.accept(c.now)) return unknown();
  launch_={e4::get(c.journal.data()+16,8),e4::get(c.journal.data()+24,8),
           e4::get(c.journal.data()+8,8),true};
  // Validate chronology in chronological order, never trust a wire ACK.
  e4::ClockValidator chronology;
  if (!chronology.accept(c.issued) || !chronology.accept(launch_) ||
      !chronology.accept(c.now) || !timely()) return unknown();
  return persist(State::consumed) && persist(State::intent);
}
bool Custodian::timely() {
  auto n=read_clock();
  return clock_.accept(n) && e4::window(frozen_.target.grant,n) &&
         n.mono>=launch_.mono && n.mono-launch_.mono<30000;
}
e4::WorkerStart Custodian::create() {
  if (!accepted_ || attempted_ || stopped_ || state_!=State::accepted) {unknown();return {};}
  attempted_=true; // never reconstructed/replayed on a failed proof
  if (!proof() || !persist(State::attempt) || !timely()) {unknown();return {};}
  try {
    auto s=owner_.create();
    if (!s.created || !s.pid) {unknown();return s;}
    identity_=owner_.process_identity();
    if (identity_.pid!=s.pid || !identity_.creation_time ||
        identity_.target_sha256!=frozen_.hash() ||
        identity_.owner!=frozen_.manifest.custody_owner ||
        identity_.image_sha256!=frozen_.target.grant.exe_sha256 ||
        identity_.account_sha256!=frozen_.target.grant.account_identity_sha256 ||
        !identity_.primary_medium || !identity_.non_elevated || !timely() ||
        !persist(State::identity)) {unknown();return s;}
    return s;
  } catch (...) {unknown();return {};}
}
r1::ProcessIdentity Custodian::process_identity() {
  if (state_!=State::identity) return {};
  return identity_;
}
r1::CustodyReceipt Custodian::acknowledge_identity(const r1::ProcessIdentity &p) {
  if (state_!=State::identity || p.hash()!=identity_.hash() || !timely()) {unknown();return {};}
  auto a=owner_.acknowledge_identity(p);
  if (a.status!=r1::IoStatus::kOk || !a.owns_process_and_thread ||
      a.process_identity_sha256!=identity_.hash() || !persist(State::acknowledged)) {
    unknown();return {};
  }
  return receipt(true);
}
bool Custodian::token() {return state_==State::identity && ++calls_[0]==1 && owner_.token();}
bool Custodian::image() {return state_==State::identity && ++calls_[1]==1 && owner_.image();}
bool Custodian::handles() {return state_==State::identity && ++calls_[2]==1 && owner_.handles();}
bool Custodian::dependencies() {
  return !stopped_ && ++deps_<=2 && owner_.dependencies();
}
bool Custodian::resume(bool &known) {
  known=false;
  if (state_!=State::acknowledged || stopped_ || resume_attempted_ ||
      calls_[0]!=1 || calls_[1]!=1 || calls_[2]!=1 || deps_!=1 || !timely()) return unknown();
  resume_attempted_=true;
  // Intent is persisted BEFORE Resume; a lost result remains UNKNOWN.
  if (!persist(State::resume_intent)) return false;
  auto p=owner_.process_identity();
  if (p.hash()!=identity_.hash() || !timely()) return unknown();
  try {
    if (!owner_.resume(known) || !known || !timely() || !persist(State::resumed)) return unknown();
    return true;
  } catch (...) {known=false;return unknown();}
}
bool Custodian::hello() {return state_==State::resumed && timely() && ++calls_[3]==1 && owner_.hello();}
bool Custodian::approve(const e4::ApprovalPromptModel &,e4::ApprovalUiResponse &) {return false;}
bool Custodian::sample() {
  if (++samples_>2*limits_.polls+16) return unknown();
  std::array<ResourceSample,3> s{};
  if (!owner_.sample_three(s)) return unknown();
  for (size_t i=0;i<3;++i) {
    if (!s[i].observed_at_ms || s[i].peak_working_set>limits_.process[i].working ||
        s[i].peak_commit>limits_.process[i].commit || s[i].handles>limits_.process[i].handles)
      return unknown();
    peaks_[i].observed_at_ms=s[i].observed_at_ms;
    peaks_[i].peak_working_set=(std::max)(peaks_[i].peak_working_set,s[i].peak_working_set);
    peaks_[i].peak_commit=(std::max)(peaks_[i].peak_commit,s[i].peak_commit);
    peaks_[i].handles=(std::max)(peaks_[i].handles,s[i].handles);
  }
  return true;
}
e5::Observation Custodian::observe() {
  if (++calls_[4]>2*limits_.polls+16 || stopped_) return {};
  auto o=owner_.observe();
  if (!o.healthy || !sample()) {unknown();return {};}
  if (o.exited) exit_=true;
  return o;
}
bool Custodian::next(e4::Frame &f,bool &available) {
  return !stopped_ && ++polls_<=limits_.polls && owner_.next(f,available);
}
bool Custodian::send(const e4::Frame &f) {
  return !stopped_ && ++sends_<=3 && owner_.send(f);
}
bool Custodian::close_observed_exit() {
  if (closed_ || !exit_) return false;
  closed_=true;
  // CloseHandle never substitutes for independent OS exit observation.
  if (!owner_.close_observed_exit()) return unknown();
  if (state_==State::unknown) return false; // legal close, no retroactive PASS
  return persist(State::exited) && persist(State::settled);
}
bool Custodian::close_owned_io() {
  if (io_closed_) return false;
  io_closed_=true;
  const bool ok=owner_.close_owned_io();
  if (!ok || (attempted_ && !closed_) || state_==State::unknown) return unknown();
  return persist(State::released);
}
void Custodian::controller_lost() noexcept {
  try { if (state_!=State::released && state_!=State::unknown) journal_.append(State::unknown,identity_); }
  catch (...) {}
  unknown(); owner_.controller_lost(); // KEEP original ownership, no cleanup
}
void Custodian::custodian_lost() noexcept {unknown();}

Endpoint::Endpoint(r1::Frozen f,std::string c,Custodian &o)
    :frozen_(std::move(f)),channel_(std::move(c)),custodian_(o) {}
bool Endpoint::dispatch(const Packet &request,Packet &response) {
  if (failed_) return false;
  failed_=true;
  const auto op=Op(e4::get(request.data()+6,2));
  if (unsigned(op)<1 || unsigned(op)>16 || ++sequence_>8*kPolls+64 ||
      !hex_digest(channel_,64) || !valid(request,packet(op,sequence_,frozen_,channel_))) {
    custodian_.controller_lost();return false;
  }
  response=packet(op,sequence_,frozen_,channel_);
  auto q=response.data()+112;
  bool ok=false;
  switch(op) {
  case Op::accept: {
    auto a=custodian_.accept_intent(frozen_);ok=a.status==r1::IoStatus::kOk;
    digest_at(q+8,a.external_record_sha256);break;
  }
  case Op::create: {
    auto s=custodian_.create();ok=s.created;
    e4::put(q+8,s.pid,4);break;
  }
  case Op::identity: {
    auto p=custodian_.process_identity();ok=p.pid!=0;
    e4::put(q+8,p.pid,4);e4::put(q+16,p.creation_time,8);
    digest_at(q+24,p.hash());break;
  }
  case Op::acknowledge: {
    auto p=custodian_.process_identity();
    if (digest_at(request.data()+112)!=p.hash()) break;
    auto a=custodian_.acknowledge_identity(p);ok=a.status==r1::IoStatus::kOk;
    digest_at(q+8,a.external_record_sha256);digest_at(q+40,a.process_identity_sha256);break;
  }
  case Op::token:ok=custodian_.token();break;
  case Op::image:ok=custodian_.image();break;
  case Op::dependencies:ok=custodian_.dependencies();break;
  case Op::handles:ok=custodian_.handles();break;
  case Op::resume: {bool known=false;ok=custodian_.resume(known);e4::put(q+8,known,4);break;}
  case Op::hello:ok=custodian_.hello();break;
  case Op::observe: {
    auto o=custodian_.observe();ok=o.healthy;
    e4::put(q+8,o.exited,4);e4::put(q+12,o.normal_exit,4);
    sample_encode(q+16,o.worker);sample_encode(q+48,o.controller);break;
  }
  case Op::next: {
    e4::Frame f{};bool available=false;ok=custodian_.next(f,available);
    e4::put(q+8,available,4);std::copy(f.begin(),f.end(),q+16);break;
  }
  case Op::send: {e4::Frame f{};std::copy_n(request.data()+112,64,f.begin());ok=custodian_.send(f);break;}
  case Op::close_exit:ok=custodian_.close_observed_exit();break;
  case Op::close_io:ok=custodian_.close_owned_io();break;
  case Op::stop:custodian_.controller_lost();ok=true;break;
  }
  e4::put(q,ok,4);seal(response);failed_=!ok;
  if (!ok) custodian_.controller_lost();
  return true; // a negative reply is distinct from transport loss
}
Proxy::Proxy(r1::Frozen f,std::string c,ControlPort &p,r1::CustodyPort &l)
    :frozen_(std::move(f)),channel_(std::move(c)),port_(p),local_(l) {}
bool Proxy::call(Op op,const uint8_t *bytes,size_t n) {
  if (failed_ || n>256 || ++sequence_>8*kPolls+64) return false;
  failed_=true;
  auto p=packet(op,sequence_,frozen_,channel_);
  if (n) std::copy_n(bytes,n,p.data()+112);
  seal(p);
  if (!port_.peer_checked() || !port_.exchange(p,reply_) ||
      !valid(reply_,packet(op,sequence_,frozen_,channel_)) ||
      e4::get(reply_.data()+112,4)!=1) return false;
  failed_=false;return true;
}
r1::CustodyReceipt Proxy::receipt(bool handles) {
  auto q=reply_.data()+112;
  return {r1::Origin::kFake,r1::IoStatus::kOk,frozen_.manifest.custody_owner,
    frozen_.hash(),digest_at(q+8),true,handles,handles?digest_at(q+40):std::string{}};
}
r1::CustodyReceipt Proxy::accept_intent(const r1::Frozen &f) {
  return f.hash()==frozen_.hash() && call(Op::accept)?receipt(false):r1::CustodyReceipt{};
}
e4::WorkerStart Proxy::create() {
  e4::WorkerStart s;
  if (call(Op::create)) {s.created=true;s.pid=uint32_t(e4::get(reply_.data()+120,4));}
  else s.creation_unknown=true;
  return s;
}
r1::ProcessIdentity Proxy::process_identity() {
  if (!call(Op::identity)) return {};
  auto q=reply_.data()+112;
  r1::ProcessIdentity p{uint32_t(e4::get(q+8,4)),e4::get(q+16,8),
    frozen_.target.grant.exe_sha256,frozen_.target.grant.account_identity_sha256,
    frozen_.hash(),frozen_.manifest.custody_owner,true,true};
  if (p.hash()!=digest_at(q+24)) {failed_=true;return {};}
  return p;
}
r1::CustodyReceipt Proxy::acknowledge_identity(const r1::ProcessIdentity &p) {
  std::array<uint8_t,32> d{};digest_at(d.data(),p.hash());
  return call(Op::acknowledge,d.data(),d.size())?receipt(true):r1::CustodyReceipt{};
}
bool Proxy::token(){return call(Op::token);} bool Proxy::image(){return call(Op::image);}
bool Proxy::dependencies(){return call(Op::dependencies);} bool Proxy::handles(){return call(Op::handles);}
bool Proxy::resume(bool &known){known=false;if(!call(Op::resume))return false;
  known=e4::get(reply_.data()+120,4)==1;return known;}
bool Proxy::hello(){return call(Op::hello);}
bool Proxy::approve(const e4::ApprovalPromptModel &p,e4::ApprovalUiResponse &r){return local_.approve(p,r);}
e4::ClockReading Proxy::read_clock(){return local_.read_clock();}
e5::Observation Proxy::observe(){if(!call(Op::observe))return {};
  auto q=reply_.data()+112;return {sample_decode(q+16),sample_decode(q+48),true,
    e4::get(q+8,4)==1,e4::get(q+12,4)==1};}
bool Proxy::next(e4::Frame &f,bool &available){available=false;if(!call(Op::next))return false;
  available=e4::get(reply_.data()+120,4)==1;std::copy_n(reply_.data()+128,64,f.begin());return true;}
bool Proxy::send(const e4::Frame &f){return call(Op::send,f.data(),f.size());}
bool Proxy::close_observed_exit(){return call(Op::close_exit);}
bool Proxy::close_owned_io(){return call(Op::close_io);}
void Proxy::controller_lost() noexcept {try {call(Op::stop);}catch(...){}failed_=true;}
bool PollBudget::poll(){return !failed && limit && limit<=kPolls && ++polls<=limit ? true:(failed=true,false);}
bool PollBudget::read(size_t requested,size_t returned,bool eof){
  return !failed && ++reads<=kPolls && requested && requested<=512 &&
    returned && returned<=requested && !eof ? true:(failed=true,false);}
bool PollBudget::write(size_t requested,size_t returned,uint32_t max){
  return !failed && ++writes<=max && requested && requested<=512 && returned==requested ?
    true:(failed=true,false);}
bool UiBudget::event(uint64_t now){
  if(failed || !limit || limit>kUiEvents || !duration || duration>60000 ||
     now<origin || now<last || now-origin>=duration || ++events>limit) return failed=true,false;
  last=now;return true;
}
int custodian_process_entry(int argc,wchar_t **argv) noexcept {
  if(argc!=1 || !argv || !argv[0])return 64;
  if(!allow_live_execution())return 10;
  return 10;
}
} // namespace shiroha_l1_crypto::r2
