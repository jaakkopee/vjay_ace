#pragma once

#include <Metal/Metal.h>
#include <array>

class LIFNetwork {
public:
    enum class Topology {
        Ring = 0,
        FullyConnected = 1,
        Feedforward = 2,
        SparseRandom = 3,
        SmallWorld = 4,
    };

    LIFNetwork();
    ~LIFNetwork();

    bool init(id<MTLDevice> device,
              id<MTLCommandQueue> cmdQueue,
              id<MTLLibrary> library,
              Topology topology,
              int neuronCount);

    void step(id<MTLCommandBuffer> cmdBuffer,
              id<MTLTexture> sourceTex,
              const std::array<float, 8>& bands,
              float rms,
              float dt,
              float timeSeconds);

    id<MTLTexture> stateTexture() const { return stateTex_; }

    void setTopology(Topology topology);
    void setNeuronCount(int neuronCount);

    Topology topology() const { return topology_; }
    int neuronCount() const { return neuronCount_; }

private:
    id<MTLDevice> device_ = nil;
    id<MTLCommandQueue> cmdQueue_ = nil;
    id<MTLLibrary> library_ = nil;

    id<MTLComputePipelineState> psoStep_ = nil;
    id<MTLComputePipelineState> psoToTexture_ = nil;

    id<MTLBuffer> stateBuf_[2] = {nil, nil};
    id<MTLBuffer> weightBuf_ = nil;
    id<MTLBuffer> inputBuf_ = nil;
    id<MTLTexture> stateTex_ = nil;

    Topology topology_ = Topology::Ring;
    int neuronCount_ = 0;
    int gridSize_ = 0;
    int readIndex_ = 0;

    void allocateResources();
    void rebuildWeights();
    void seedState();

    id<MTLTexture> makeStateTexture() const;
    id<MTLComputePipelineState> makePSO(NSString* kernelName) const;
};