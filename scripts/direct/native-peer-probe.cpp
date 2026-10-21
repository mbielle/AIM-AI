// AIM's synthetic native libdatachannel probe. No app, credential store or model calls.
#define RTC_STATIC 1
#define RTC_ENABLE_MEDIA 0
#define RTC_ENABLE_WEBSOCKET 0
#include <rtc/rtc.h>
#include <mbedtls/base64.h>
#include <atomic>
#include <iostream>
#include <mutex>
#include <string>
#include <vector>
#include <sstream>
static std::mutex outputMutex;
static int peer=-1;
static std::atomic<int> channel{-1};
static std::string encode(const std::string &in) {
    size_t n=0; std::string out((in.size()+2)/3*4+1,'\0');
    if(mbedtls_base64_encode((unsigned char*)out.data(),out.size(),&n,(const unsigned char*)in.data(),in.size())!=0) return {};
    out.resize(n);return out;
}
static std::string decode(const std::string &in) {
    size_t n=0;std::string out(in.size()+1,'\0');
    if(mbedtls_base64_decode((unsigned char*)out.data(),out.size(),&n,(const unsigned char*)in.data(),in.size())!=0) throw std::runtime_error("invalid base64");
    out.resize(n);return out;
}
static void emit(const std::string &line){ std::lock_guard<std::mutex> lock(outputMutex);std::cout<<line<<std::endl; }
static void open(int id,void*) {
    channel=id;
    char local[4096]={},remote[4096]={};
    int result=rtcGetSelectedCandidatePair(peer,local,sizeof(local),remote,sizeof(remote));
    const bool relay=result>=0&&(std::string(local).find("typ relay")!=std::string::npos||std::string(remote).find("typ relay")!=std::string::npos);
    emit(std::string("open\t")+(result<0?"unknown":relay?"turn":"direct"));
}
static void message(int,const char* bytes,int size,void*) { if(size<0)return;emit("message\t"+encode(std::string(bytes,(size_t)size))); }
static void configure(int dc){ channel=dc;rtcSetOpenCallback(dc,open);rtcSetMessageCallback(dc,message);rtcSetClosedCallback(dc,[](int,void*){emit("closed");}); }
int main(int argc,char**argv){
    try {
        rtcInitLogger(RTC_LOG_ERROR,nullptr);
        rtcConfiguration config={};config.maxMessageSize=262144;
        config.disableAutoNegotiation=true;
        const char* ice=argc>2?argv[2]:nullptr;
        if(ice){config.iceServers=&ice;config.iceServersCount=1;}
        if(argc>3&&std::string(argv[3])=="relay")config.iceTransportPolicy=RTC_TRANSPORT_POLICY_RELAY;
        peer=rtcCreatePeerConnection(&config);if(peer<0)return 2;
        rtcSetLocalDescriptionCallback(peer,[](int,const char*sdp,const char*type,void*){emit("description\t"+encode(sdp)+"\t"+type);});
        rtcSetLocalCandidateCallback(peer,[](int,const char*candidate,const char*mid,void*){emit("candidate\t"+encode(candidate)+"\t"+encode(mid));});
        rtcSetStateChangeCallback(peer,[](int,rtcState state,void*){emit("state\t"+std::to_string((int)state));});
        rtcSetDataChannelCallback(peer,[](int,int dc,void*){configure(dc);});
        if(argc>1&&std::string(argv[1])=="offerer"){
            int dc=rtcCreateDataChannel(peer,"aim-direct-v1");if(dc<0)return 3;configure(dc);
            if(rtcSetLocalDescription(peer,"offer")<0)return 4;
        }
        std::string line;
        while(std::getline(std::cin,line)){
            std::vector<std::string> fields;std::istringstream input(line);std::string field;
            while(std::getline(input,field,'\t'))fields.push_back(field);
            int result=0;
            if(fields.size()==3&&fields[0]=="description"){
                result=rtcSetRemoteDescription(peer,decode(fields[1]).c_str(),fields[2].c_str());
                if(result>=0&&fields[2]=="offer")result=rtcSetLocalDescription(peer,"answer");
            }else if(fields.size()==3&&fields[0]=="candidate")result=rtcAddRemoteCandidate(peer,decode(fields[1]).c_str(),decode(fields[2]).c_str());
            else if(fields.size()==2&&fields[0]=="send"){
                const auto bytes=decode(fields[1]);if(channel<0||!rtcIsOpen(channel))return 5;
                result=rtcSendMessage(channel,bytes.data(),(int)bytes.size());
            }else if(fields[0]=="close")break;
            else return 6;
            if(result<0){emit("error\t"+std::to_string(result));return 7;}
        }
        if(channel>=0)rtcDeleteDataChannel(channel);rtcDeletePeerConnection(peer);
        return 0;
    }catch(const std::exception&){return 8;}
}
