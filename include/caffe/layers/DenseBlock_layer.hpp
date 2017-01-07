#ifndef CAFFE_DENSEBLOCK_LAYER_HPP_
#define CAFFE_DENSEBLOCK_LAYER_HPP_

#include <vector>

#include "caffe/blob.hpp"
#include "caffe/layer.hpp"
#include "caffe/proto/caffe.pb.h"

namespace caffe {

template <typename Dtype>
class DenseBlockLayer : public Layer<Dtype> {
 public:
  explicit DenseBlockLayer(const LayerParameter& param)
      : Layer<Dtype>(param) {}

  virtual void LayerSetUp(const vector<Blob<Dtype>*>& bottom, const vector<Blob<Dtype>*>& top);
  
  virtual void Reshape(const vector<Blob<Dtype>*>& bottom, const vector<Blob<Dtype>*>& top); 
  
  virtual inline const char* type() const { return "DenseBlock"; } 

 protected:
  virtual void Forward_cpu(const vector<Blob<Dtype>*>& bottom,
      const vector<Blob<Dtype>*>& top);
  
  virtual void Forward_gpu(const vector<Blob<Dtype>*>& bottom,
      const vector<Blob<Dtype>*>& top);

  virtual void Backward_cpu(const vector<Blob<Dtype>*>& top,
      const vector<bool>& propagate_down, const vector<Blob<Dtype>*>& bottom);
  
  virtual void Backward_gpu(const vector<Blob<Dtype>*>& top,
      const vector<bool>& propagate_down, const vector<Blob<Dtype>*>& bottom);

  //common Blobs for both CPU & GPU mode
  //in this->blobs_, containing all filters for Convolution, scalers and bias for BN
  
  //start CPU specific data section
  bool cpuInited;
  vector<Blob<Dtype>*> global_Mean;
  vector<Blob<Dtype>*> batch_Mean;
  vector<Blob<Dtype>*> global_Var;
  vector<Blob<Dtype>*> batch_Var;

  vector<Blob<Dtype>*> postBN_blobVec;
  vector<Blob<Dtype>*> postReLU_blobVec;
  vector<Blob<Dtype>*> postConv_blobVec;
  //end CPU specific data section

  //start GPU specific data section
  //GPU ptr for efficient space usage only, these pointers not allocated when CPU_ONLY, these are not Blobs because Descriptor is not traditional 
  Dtype* postConv_data_gpu;
  Dtype* postConv_grad_gpu;
  Dtype* postBN_data_gpu;
  Dtype* postBN_grad_gpu;
  Dtype* postReLU_data_gpu;
  Dtype* postReLU_grad_gpu;
  Dtype* workspace;
  Dtype* ResultRunningMean_gpu;
  Dtype* ResultRunningVariance_gpu;
  Dtype* ResultSaveMean_gpu;
  Dtype* ResultSaveInvVariance_gpu;
  
  int initChannel, growthRate, numTransition; 
  int N,H,W; //N,H,W of the input tensor, inited in reshape phase
  int trainCycleIdx; //used in BN train phase for EMA Mean/Var estimation
  //convolution Related
  int pad_h, pad_w, conv_verticalStride, conv_horizentalStride; 
  int filter_H, filter_W;
  //gpu workspace size
  int workspace_size_bytes;
  //gpu handles and descriptors
  cudnnHandle_t* cudnnHandlePtr;
  vector<cudnnTensorDescriptor_t *> tensorDescriptorVec_narrow;//for BN & ReLU
  vector<cudnnTensorDescriptor_t *> tensorDescriptorVec_conv_x;//local Conv X
  cudnnTensorDescriptor_t * tensorDescriptor_conv_y;//local Conv Y
  cudnnTensorDescriptor_t * tensorDescriptor_BN_initChannel;//BN when transitionIdx = 0
  cudnnTensorDescriptor_t * tensorDescriptor_BN_growthRate;//BN when transitionIdx > 0
  cudnnActivationDescriptor_t * activationDesc;
  //filter descriptor for conv
  vector<cudnnFilterDescriptor_t *> filterDescriptorVec;
  //conv descriptor for conv
  cudnnConvolutionDescriptor_t* conv_Descriptor;

  //end GPU specific data setion
};

}  // namespace caffe

#endif  // CAFFE_DENSEBLOCK_LAYER_HPP_
