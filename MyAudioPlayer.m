//
//  MyAudioPlayer.m
//  UUSmartHome
//
//  Created by vsKing on 2017/7/12.
//  Copyright © 2017年 Fuego. All rights reserved.
//




#import "MyAudioPlayer.h"

#include <stdio.h>
#include <string.h>
#include <netdb.h>
#include <netinet/in.h>
#include <unistd.h>
#include <pthread.h>
#include <AudioToolbox/AudioToolbox.h>


#define PRINTERROR(LABEL)   printf("%s err %4.4s %ld\n", LABEL, (char *)&err, err)

const int port = 51515;         // the port we will use

const unsigned int kNumAQBufs = 3;          // number of audio queue buffers we allocate
const size_t kAQBufSize = 128 * 1024;       // number of bytes in each audio queue buffer
const size_t kAQMaxPacketDescs = 512;       // number of packet descriptions in our array

struct MyData
{
    AudioFileStreamID audioFileStream;  // the audio file stream parser
    
    AudioQueueRef audioQueue;                               // the audio queue
    AudioQueueBufferRef audioQueueBuffer[kNumAQBufs];       // audio queue buffers
    
    AudioStreamPacketDescription packetDescs[kAQMaxPacketDescs];    // packet descriptions for enqueuing audio
    
    unsigned int fillBufferIndex;   // the index of the audioQueueBuffer that is being filled
    size_t bytesFilled;             // how many bytes have been filled
    size_t packetsFilled;           // how many packets have been filled
    
    bool inuse[kNumAQBufs];         // flags to indicate that a buffer is still in use
    bool started;                   // flag to indicate that the queue has been started
    bool failed;                    // flag to indicate an error occurred
    
    pthread_mutex_t mutex;          // a mutex to protect the inuse flags
    pthread_cond_t cond;            // a condition varable for handling the inuse flags
    pthread_cond_t done;            // a condition varable for handling the inuse flags
};
typedef struct MyData MyData;

int  MyConnectSocket();

void MyAudioQueueOutputCallback(void* inClientData, AudioQueueRef inAQ, AudioQueueBufferRef inBuffer);
void MyAudioQueueIsRunningCallback(void *inUserData, AudioQueueRef inAQ, AudioQueuePropertyID inID);

void MyPropertyListenerProc(    void *                          inClientData,
                            AudioFileStreamID               inAudioFileStream,
                            AudioFileStreamPropertyID       inPropertyID,
                            UInt32 *                        ioFlags);

void MyPacketsProc(             void *                          inClientData,
                   UInt32                          inNumberBytes,
                   UInt32                          inNumberPackets,
                   const void *                    inInputData,
                   AudioStreamPacketDescription    *inPacketDescriptions);

OSStatus MyEnqueueBuffer(MyData* myData);

void WaitForFreeBuffer(MyData* myData);





@interface MyAudioPlayer ()
{
    MyData * _MYDATA;
    
}
@end

@implementation MyAudioPlayer


+ (MyAudioPlayer *)sharedInstance{
    static MyAudioPlayer *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[MyAudioPlayer alloc] init];
    });
    return instance;
}



- (void)initAudio{
    // allocate a struct for storing our state
    _MYDATA = (MyData*)calloc(1, sizeof(MyData));
    
    // initialize a mutex and condition so that we can block on buffers in use.
    pthread_mutex_init(&_MYDATA->mutex, NULL);
    pthread_cond_init(&_MYDATA->cond, NULL);
    pthread_cond_init(&_MYDATA->done, NULL);
    
    // create an audio file stream parser
    AudioFileStreamOpen(_MYDATA, MyPropertyListenerProc, MyPacketsProc,
                                       kAudioFileAAC_ADTSType, &_MYDATA->audioFileStream);
    
    AudioQueueSetParameter(_MYDATA->audioQueue, kAudioQueueParam_Volume, 1.0);
    
}

- (void)addPacket:(NSData *)data{
    
//    printf("->recv\n");
//    ssize_t bytesRecvd = recv(connection_socket, buf, kRecvBufSize, 0);
//    printf("bytesRecvd %ld\n", bytesRecvd);
//    if (bytesRecvd <= 0) break; // eof or failure
    
    // parse the data. this will call MyPropertyListenerProc and MyPacketsProc
    
    if (data) {
        
        char * buf = (char *)data.bytes;
        int len = data.length;
        
        AudioFileStreamParseBytes(_MYDATA->audioFileStream, len, buf, 0);
        
    }
    
    
    
    
}

-(void)play{
    [self initAudio];
}


- (void)stop{
    AudioQueueFlush(_MYDATA->audioQueue);
    
    AudioQueueStop(_MYDATA->audioQueue, true);
    
    printf("waiting until finished playing..\n");
//    pthread_mutex_lock(&_MYDATA->mutex);
//    pthread_cond_wait(&_MYDATA->done, &_MYDATA->mutex);
//    pthread_mutex_unlock(&_MYDATA->mutex);
    
    
    printf("done\n");
    
    AudioFileStreamClose(_MYDATA->audioFileStream);
    AudioQueueDispose(_MYDATA->audioQueue, true);
    free(_MYDATA);
}





void MyPropertyListenerProc(    void *                          inClientData,
                            AudioFileStreamID               inAudioFileStream,
                            AudioFileStreamPropertyID       inPropertyID,
                            UInt32 *                        ioFlags)
{
    // this is called by audio file stream when it finds property values
    MyData* myData = (MyData*)inClientData;
    OSStatus err = noErr;
    
    printf("found property '%c%c%c%c'\n", (char)(inPropertyID>>24)&255, (char)(inPropertyID>>16)&255, (char)(inPropertyID>>8)&255, (char)inPropertyID&255);
    
    switch (inPropertyID) {
        case kAudioFileStreamProperty_ReadyToProducePackets :
        {
            // the file stream parser is now ready to produce audio packets.
            // get the stream format.
            AudioStreamBasicDescription asbd;
            UInt32 asbdSize = sizeof(asbd);
            err = AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_DataFormat, &asbdSize, &asbd);
            if (err) { PRINTERROR("get kAudioFileStreamProperty_DataFormat"); myData->failed = true; break; }
            
            // create the audio queue
            err = AudioQueueNewOutput(&asbd, MyAudioQueueOutputCallback, myData, NULL, NULL, 0, &myData->audioQueue);
            if (err) { PRINTERROR("AudioQueueNewOutput"); myData->failed = true; break; }
            
            // allocate audio queue buffers
            for (unsigned int i = 0; i < kNumAQBufs; ++i) {
                err = AudioQueueAllocateBuffer(myData->audioQueue, kAQBufSize, &myData->audioQueueBuffer[i]);
                if (err) { PRINTERROR("AudioQueueAllocateBuffer"); myData->failed = true; break; }
            }
            
            // get the cookie size
            UInt32 cookieSize;
            Boolean writable;
            err = AudioFileStreamGetPropertyInfo(inAudioFileStream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, &writable);
            if (err) { PRINTERROR("info kAudioFileStreamProperty_MagicCookieData"); break; }
            printf("cookieSize %d\n", (unsigned int)cookieSize);
            
            // get the cookie data
            void* cookieData = calloc(1, cookieSize);
            err = AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, cookieData);
            if (err) { PRINTERROR("get kAudioFileStreamProperty_MagicCookieData"); free(cookieData); break; }
            
            // set the cookie on the queue.
            err = AudioQueueSetProperty(myData->audioQueue, kAudioQueueProperty_MagicCookie, cookieData, cookieSize);
            free(cookieData);
            if (err) { PRINTERROR("set kAudioQueueProperty_MagicCookie"); break; }
            
            // listen for kAudioQueueProperty_IsRunning
            err = AudioQueueAddPropertyListener(myData->audioQueue, kAudioQueueProperty_IsRunning, MyAudioQueueIsRunningCallback, myData);
            if (err) { PRINTERROR("AudioQueueAddPropertyListener"); myData->failed = true; break; }
            
            break;
        }
    }
}

void MyPacketsProc(             void *                          inClientData,
                   UInt32                          inNumberBytes,
                   UInt32                          inNumberPackets,
                   const void *                    inInputData,
                   AudioStreamPacketDescription    *inPacketDescriptions)
{
    // this is called by audio file stream when it finds packets of audio
    MyData* myData = (MyData*)inClientData;
    printf("got data.  bytes: %d  packets: %d\n", (unsigned int)inNumberBytes, (unsigned int)inNumberPackets);
    
    // the following code assumes we're streaming VBR data. for CBR data, you'd need another code branch here.
    
    for (int i = 0; i < inNumberPackets; ++i) {
        
        SInt64 packetOffset = inPacketDescriptions[i].mStartOffset;
        SInt64 packetSize   = inPacketDescriptions[i].mDataByteSize;
        
        // if the space remaining in the buffer is not enough for this packet, then enqueue the buffer.
        size_t bufSpaceRemaining = kAQBufSize - myData->bytesFilled;
//        if (bufSpaceRemaining < packetSize) {
//            MyEnqueueBuffer(myData);
//            WaitForFreeBuffer(myData);
//        }
//
        // copy data to the audio queue buffer
        AudioQueueBufferRef fillBuf = myData->audioQueueBuffer[myData->fillBufferIndex];
        memcpy((char*)fillBuf->mAudioData + myData->bytesFilled, (const char*)inInputData + packetOffset, packetSize);
        // fill out packet description
        myData->packetDescs[myData->packetsFilled] = inPacketDescriptions[i];
        myData->packetDescs[myData->packetsFilled].mStartOffset = myData->bytesFilled;
        // keep track of bytes filled and packets filled
        myData->bytesFilled += packetSize;
        myData->packetsFilled += 1;
        
        // if that was the last free packet description, then enqueue the buffer.
        size_t packetsDescsRemaining = kAQMaxPacketDescs - myData->packetsFilled;
//        if (packetsDescsRemaining == 0) {
            NSLog(@"准备插入");
            
            MyEnqueueBuffer(myData);
            WaitForFreeBuffer(myData);
//        }
    }
}

OSStatus StartQueueIfNeeded(MyData* myData)
{
    OSStatus err = noErr;
    if (!myData->started) {     // start the queue if it has not been started already
        err = AudioQueueStart(myData->audioQueue, NULL);
        if (err) {
            PRINTERROR("AudioQueueStart");
            myData->failed = true;
            return err;
        }
        myData->started = true;
        printf("started\n");
    }
    return err;
}

OSStatus MyEnqueueBuffer(MyData* myData)
{
    OSStatus err = noErr;
    myData->inuse[myData->fillBufferIndex] = true;      // set in use flag
    
    // enqueue buffer
    AudioQueueBufferRef fillBuf = myData->audioQueueBuffer[myData->fillBufferIndex];
    fillBuf->mAudioDataByteSize = myData->bytesFilled;
    err = AudioQueueEnqueueBuffer(myData->audioQueue, fillBuf, myData->packetsFilled, myData->packetDescs);
    if (err) { PRINTERROR("AudioQueueEnqueueBuffer"); myData->failed = true; return err; }
    
    NSLog(@"插入----------->");
    
    
    StartQueueIfNeeded(myData);
    
    return err;
}


void WaitForFreeBuffer(MyData* myData)
{
    // go to next buffer
    if (++myData->fillBufferIndex >= kNumAQBufs) myData->fillBufferIndex = 0;
    myData->bytesFilled = 0;        // reset bytes filled
    myData->packetsFilled = 0;      // reset packets filled
    
    // wait until next buffer is not in use
    printf("->lock\n");
    pthread_mutex_lock(&myData->mutex);
    while (myData->inuse[myData->fillBufferIndex]) {
        printf("... WAITING ...\n");
        pthread_cond_wait(&myData->cond, &myData->mutex);
    }
    pthread_mutex_unlock(&myData->mutex);
    printf("<-unlock\n");
}

int MyFindQueueBuffer(MyData* myData, AudioQueueBufferRef inBuffer)
{
    for (unsigned int i = 0; i < kNumAQBufs; ++i) {
        if (inBuffer == myData->audioQueueBuffer[i])
            return i;
    }
    return -1;
}


void MyAudioQueueOutputCallback(    void*                   inClientData,
                                AudioQueueRef           inAQ,
                                AudioQueueBufferRef     inBuffer)
{
    // this is called by the audio queue when it has finished decoding our data.
    // The buffer is now free to be reused.
    
    
    NSLog(@"MyAudioQueueOutputCallback");
    
    
    MyData* myData = (MyData*)inClientData;
    
    unsigned int bufIndex = MyFindQueueBuffer(myData, inBuffer);
    
    // signal waiting thread that the buffer is free.
    pthread_mutex_lock(&myData->mutex);
    myData->inuse[bufIndex] = false;
    pthread_cond_signal(&myData->cond);
    pthread_mutex_unlock(&myData->mutex);
}

void MyAudioQueueIsRunningCallback(     void*                   inClientData,
                                   AudioQueueRef           inAQ,
                                   AudioQueuePropertyID    inID)
{
    MyData* myData = (MyData*)inClientData;
    
    UInt32 running;
    UInt32 size;
    OSStatus err = AudioQueueGetProperty(inAQ, kAudioQueueProperty_IsRunning, &running, &size);
    if (err) { PRINTERROR("get kAudioQueueProperty_IsRunning"); return; }
    if (!running) {
        pthread_mutex_lock(&myData->mutex);
        pthread_cond_signal(&myData->done);
        pthread_mutex_unlock(&myData->mutex);
    }
}



@end
