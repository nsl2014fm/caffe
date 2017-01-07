#include <vector>

#include "caffe/layers/DenseBlock_layer.hpp"

namespace caffe {

template <typename Dtype>
void gpu_copy_one_to_many(const Dtype* inPtr_gpu,Dtype* outPtr_gpu,int numChunks,int chunkSize_input,int chunkStride_output){
    for (int chunkIdx=0;chunkIdx<numChunks;++chunkIdx){
	const Dtype* inPtr_local = inPtr_gpu + chunkIdx*chunkSize_input; 
	Dtype* outPtr_local = outPtr_gpu + chunkIdx*chunkStride_output;
        CUDA_CHECK(cudaMemcpy(outPtr_local,inPtr_local,chunkSize_input * sizeof(Dtype),cudaMemcpyDeviceToDevice));
    }
}

template <typename Dtype>
void gpu_copy_many_to_one(Dtype* inPtr_gpu,Dtype* outPtr_gpu,int numChunks,int chunkSize_output,int chunkStride_input){
    for (int chunkIdx=0;chunkIdx<numChunks;++chunkIdx){
        Dtype* inPtr_local = inPtr_gpu + chunkIdx*chunkStride_input;
	Dtype* outPtr_local = outPtr_gpu + chunkIdx*chunkSize_output;
	CUDA_CHECK(cudaMemcpy(inPtr_local,outPtr_local,chunkSize_output * sizeof(Dtype),cudaMemcpyDeviceToDevice));
    }
}

template <typename Dtype>
void DenseBlockLayer<Dtype>::Forward_gpu(const vector<Blob<Dtype>*>& bottom,
    const vector<Blob<Dtype>*>& top) {
  const Dtype* bottom_data = bottom[0]->gpu_data();
  Dtype* top_data = top[0]->mutable_gpu_data();
  const int count = bottom[0]->count();
  //copy to bottom_data to buffer with stride
  int chunkSize_copy_init = this->initChannel * this->H * this->W;
  int chunkStride_copy = (this->initChannel + this->growthRate * this->numTransition) * this->H * this->W;
  gpu_copy_one_to_many<Dtype>(bottom_data,this->postConv_data_gpu,this->N,chunkSize_copy_init,chunkStride_copy);
  //work in the buffer, transition by transition
  for (int transitionIdx=0;transitionIdx < this->numTransition;++transitionIdx){
      //BN and ReLU
      int channelsBefore_noself = (transitionIdx==0?0:(this->initChannel + (transitionIdx - 1)*this->growthRate));
      Dtype* BN_x_ptr = this->postConv_data_gpu + channelsBefore_noself * this->H * this->W;  
      Dtype* BN_y_ptr = this->postBN_data_gpu + channelsBefore_noself * this->H * this->W;
      Dtype* ReLU_y_ptr = this->postReLU_data_gpu + channelsBefore_noself * this->H * this->W;
      //BN
      Dtype* BN_mean_local = this->ResultRunningMean_gpu + channelsBefore_noself;
      Dtype* BN_var_local = this->ResultRunningVariance_gpu + channelsBefore_noself;
      cudnnTensorDescriptor_t * localBN_paramDesc = (transitionIdx==0?tensorDescriptor_BN_initChannel:tensorDescriptor_BN_growthRate);
      if (this->phase_ == TEST){
          CUDNN_CHECK(cudnnBatchNormalizationForwardInference(
	    *(this->cudnnHandlePtr),CUDNN_BATCHNORM_SPATIAL,
	    cudnn::dataType<Dtype>::one,cudnn::dataType<Dtype>::zero,
	    *(this->tensorDescriptorVec_narrow[transitionIdx]),BN_x_ptr,
	    *(this->tensorDescriptorVec_narrow[transitionIdx]),BN_y_ptr,
	    *localBN_paramDesc,
	    this->blobs_[this->numTransition + transitionIdx]->gpu_data(),
            this->blobs_[2 * this->numTransition + transitionIdx]->gpu_data(),
	    BN_mean_local,BN_var_local,CUDNN_BN_MIN_EPSILON)
	  );
      }
      else{
          Dtype* resultSaveMean_local = this->ResultSaveMean_gpu + channelsBefore_noself;
          Dtype* resultSaveInvVariance_local =  this->ResultSaveInvVariance_gpu + channelsBefore_noself;
	  double EMA_factor = 1.0/(1+this->trainCycleIdx);	  
	  CUDNN_CHECK(cudnnBatchNormalizationForwardTraining(
	    *(this->cudnnHandlePtr),CUDNN_BATCHNORM_SPATIAL,
	    cudnn::dataType<Dtype>::one,cudnn::dataType<Dtype>::zero,
	    *(this->tensorDescriptorVec_narrow[transitionIdx]),BN_x_ptr,
	    *(this->tensorDescriptorVec_narrow[transitionIdx]),BN_y_ptr,
	    *localBN_paramDesc,
	    this->blobs_[this->numTransition + transitionIdx]->gpu_data(),
	    this->blobs_[2 * this->numTransition + transitionIdx]->gpu_data(),
	    EMA_factor,BN_mean_local,BN_var_local,CUDNN_BN_MIN_EPSILON,
	    resultSaveMean_local,resultSaveInvVariance_local)
	  );
	  this->trainCycleIdx += 1;
      } 
      //ReLU
      CUDNN_CHECK(cudnnActivationForward(*(this->cudnnHandlePtr),
	*(this->activationDesc), cudnn::dataType<Dtype>::one, 
	*(this->tensorDescriptorVec_narrow[transitionIdx]),BN_y_ptr,
	cudnn::dataType<Dtype>::zero,
	*(this->tensorDescriptorVec_narrow[transitionIdx]),ReLU_y_ptr)
      );
      //Convolution
      int delayChannel = this->initChannel + this->growthRate * transitionIdx;
      Dtype* conv_x_local = postReLU_data_gpu;
      Dtype* conv_y_local = postConv_data_gpu + delayChannel * this->H * this->W;
      CUDNN_CHECK(cudnnConvolutionForward(*(this->cudnnHandlePtr),
	cudnn::dataType<Dtype>::one,
	*(this->tensorDescriptorVec_conv_x[transitionIdx]),conv_x_local,
	*(this->filterDescriptorVec[transitionIdx]),
	this->blobs_[transitionIdx]->gpu_data(),
	*(this->conv_Descriptor),CUDNN_CONVOLUTION_FWD_ALGO_IMPLICIT_GEMM,
	this->workspace,this->workspace_size_bytes,cudnn::dataType<Dtype>::zero,
	*(this->tensorDescriptor_conv_y),conv_y_local	
	)		      
      ); 
  } 
  //change top data
  int chunkSize_copy_end = this->growthRate * this->H * this->W;
  int resultChannelGap = this->initChannel + this->growthRate * (this->numTransition - 1);
  Dtype* resultBuffer_ptr = postConv_data_gpu + resultChannelGap * this->H * this->W;
  gpu_copy_many_to_one<Dtype>(resultBuffer_ptr,top_data,this->N,chunkSize_copy_end,chunkStride_copy);
}

template <typename Dtype>
void DenseBlockLayer<Dtype>::Backward_gpu(const vector<Blob<Dtype>*>& top,
    const vector<bool>& propagate_down,
    const vector<Blob<Dtype>*>& bottom) {

    //assuming buffers store already computed value, always propagate down
    const Dtype* top_diff = top[0]->gpu_diff();
    Dtype* bottom_diff = bottom[0]->mutable_gpu_diff();
    const int count = bottom[0]->count();
    //deploy top diff to buffer
    int chunkSize_copy_init = this->initChannel * this->H * this->W;
    int chunkSize_copy_end = this->growthRate * this->H * this->W;
    int chunkStride_copy = (this->initChannel + this->growthRate * this->numTransition) * this->H * this->W;
    int resultChannelGap = this->initChannel + this->growthRate * (this->numTransition - 1);
    Dtype* targetDeploy_ptr = this->postConv_grad_gpu + resultChannelGap * this->H * this->W; 
    gpu_copy_one_to_many(top_diff,targetDeploy_ptr,this->N,chunkSize_copy_end,chunkStride_copy);    
    //Backward, transition by transition
    for (int transitionIdx=this->numTransition-1;transitionIdx>=0;--transitionIdx){
        int channelsBefore_noself = this->initChannel + transitionIdx * this->growthRate;
        int channelsBefore_self = transitionIdx>0?(this->initChannel + (transitionIdx - 1) * this->growthRate):0;
	//Conv
        Dtype* filterGrad_local = this->blobs_[transitionIdx]->mutable_gpu_diff();
	const Dtype* filterData_local =this->blobs_[transitionIdx]->gpu_data();
	Dtype* conv_x_local = postReLU_data_gpu;
	Dtype* conv_dy_local = postConv_grad_gpu + channelsBefore_self * this->H * this->W;
	//Conv w.r.t. filter
	CUDNN_CHECK(cudnnConvolutionBackwardFilter(*(this->cudnnHandlePtr),
	  cudnn::dataType<Dtype>::one, 
	  *(this->tensorDescriptorVec_conv_x[transitionIdx]),conv_x_local,
	  *(this->tensorDescriptor_conv_y),conv_dy_local,
	  *(this->conv_Descriptor),CUDNN_CONVOLUTION_BWD_FILTER_ALGO_1,
	  this->workspace,this->workspace_size_bytes,
	  cudnn::dataType<Dtype>::zero,
	  *(this->filterDescriptorVec[transitionIdx]),filterGrad_local	  
	  )		
	);
	//Conv w.r.t. x
	CUDNN_CHECK(cudnnConvolutionBackwardData(*(this->cudnnHandlePtr),
	  cudnn::dataType<Dtype>::one,
	  *(this->filterDescriptorVec[transitionIdx]),filterData_local,
	  *(this->tensorDescriptor_conv_y),conv_dy_local,
	  *(this->conv_Descriptor),CUDNN_CONVOLUTION_BWD_DATA_ALGO_1,
	  this->workspace,this->workspace_size_bytes,
	  cudnn::dataType<Dtype>::one,
	  *(this->tensorDescriptorVec_conv_x[transitionIdx]),postReLU_grad_gpu
	  )		
	);	
	//ReLU
	Dtype* ReLU_y_local = postReLU_data_gpu + channelsBefore_noself*this->H*this->W;
	Dtype* ReLU_x_local = postBN_data_gpu + channelsBefore_noself*this->H*this->W;
	Dtype* ReLU_dy_local = postReLU_grad_gpu + channelsBefore_noself*this->H*this->W;
        Dtype* ReLU_dx_local = postBN_grad_gpu + channelsBefore_noself*this->H*this->W;	
	CUDNN_CHECK(cudnnActivationBackward(*(this->cudnnHandlePtr),
	  *(this->activationDesc),cudnn::dataType<Dtype>::one,
	  *(this->tensorDescriptorVec_narrow[transitionIdx]),ReLU_y_local,
	  *(this->tensorDescriptorVec_narrow[transitionIdx]),ReLU_dy_local,
	  *(this->tensorDescriptorVec_narrow[transitionIdx]),ReLU_x_local,
	  cudnn::dataType<Dtype>::zero,
	  *(this->tensorDescriptorVec_narrow[transitionIdx]),ReLU_dx_local  
	  )
	);
	//BN
	Dtype* BN_x_local = postConv_data_gpu + channelsBefore_noself*this->H*this->W;
	Dtype* BN_dx_local = postConv_grad_gpu + channelsBefore_noself*this->H*this->W;
	Dtype* saveMean_local = this->ResultSaveMean_gpu + channelsBefore_noself; 
	Dtype* saveInvVar_local = this->ResultSaveInvVariance_gpu + channelsBefore_noself;
	cudnnTensorDescriptor_t * BNparam_desc = (transitionIdx==0?this->tensorDescriptor_BN_initChannel:this->tensorDescriptor_BN_growthRate);
	CUDNN_CHECK(cudnnBatchNormalizationBackward(*(this->cudnnHandlePtr),
	  CUDNN_BATCHNORM_SPATIAL,
	  cudnn::dataType<Dtype>::one,cudnn::dataType<Dtype>::zero,
	  cudnn::dataType<Dtype>::one,cudnn::dataType<Dtype>::zero,
	  *(this->tensorDescriptorVec_narrow[transitionIdx]),BN_x_local,
	  *(this->tensorDescriptorVec_narrow[transitionIdx]),ReLU_dx_local,
	  *(this->tensorDescriptorVec_narrow[transitionIdx]),BN_dx_local,
	  *BNparam_desc,
	  this->blobs_[this->numTransition + transitionIdx]->gpu_data(),
	  this->blobs_[this->numTransition + transitionIdx]->mutable_gpu_diff(),
	  this->blobs_[2*this->numTransition + transitionIdx]->mutable_gpu_diff(),
	  CUDNN_BN_MIN_EPSILON,saveMean_local,saveInvVar_local
	  )		
	);
    }
    //deploy buffer to bottom diff 
    gpu_copy_many_to_one(postConv_grad_gpu,bottom_diff,this->N,chunkSize_copy_init,chunkStride_copy); 
}

INSTANTIATE_LAYER_GPU_FUNCS(DenseBlockLayer);

}  // namespace caffe