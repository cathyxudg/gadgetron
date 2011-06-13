#include "cgOperatorCartesianSense.h"
#include "cuNDFFT.h"
#include "ndarray_vector_td_utilities.h"

template<class REAL> __global__ void 
sample_array_kernel( typename complext<REAL>::Type* in, typename complext<REAL>::Type* out, 
		     unsigned int* idx, 
		     unsigned long image_elements,
		     unsigned long int samples,
		     unsigned int coils )
{
  unsigned long idx_in = blockIdx.x*blockDim.x+threadIdx.x;
  if (idx_in < samples) {
    for (unsigned int i = 0; i < coils; i++) {
      out[idx_in + i*samples].vec[0] += in[idx[idx_in] + i*image_elements].vec[0];
      out[idx_in + i*samples].vec[1] += in[idx[idx_in] + i*image_elements].vec[1];
    }
  }
}

template<class REAL> __global__ void 
insert_samples_kernel( typename complext<REAL>::Type* in, typename complext<REAL>::Type* out, 
				       unsigned int* idx, 
				       unsigned long image_elements,
				       unsigned long int samples,
				       unsigned int coils )
{
  unsigned long idx_in = blockIdx.x*blockDim.x+threadIdx.x;
  if (idx_in < samples) {
    for (unsigned int i = 0; i < coils; i++) {
      out[idx[idx_in] + i*image_elements].vec[0] += in[idx_in + i*samples].vec[0];
      out[idx[idx_in] + i*image_elements].vec[1] += in[idx_in + i*samples].vec[1];
    }
  }
}

template<class REAL, unsigned int D> int 
cgOperatorCartesianSense<REAL,D>::mult_M( cuNDArray<_complext>* in, cuNDArray<_complext>* out, bool accumulate )
{
  if (!(in->dimensions_equal(&this->dimensionsI_)) || !(out->dimensions_equal(&this->dimensionsK_)) ) {

    std::cerr << "cgOperatorCartesianSense::mult_M dimensions mismatch" << std::endl;

    return -1;
  }

  cuNDArray<_complext> tmp;
  std::vector<unsigned int> full_dimensions = this->dimensionsI_;
  full_dimensions.push_back(this->ncoils_);

  if (!tmp.create(&full_dimensions)) {
    std::cerr << "cgOperatorCartesianSense::mult_M unable to allocate temp array" << std::endl;
    return -1;    
  }

  if (mult_csm(in,&tmp) < 0) {
    std::cerr << "cgOperatorCartesianSense::mult_M : Unable to multiply with coil sensitivities" << std::endl;
    return -1;
  }

  cuNDFFT ft;
  std::vector<unsigned int> ft_dims;
  for (unsigned int i = 0; i < this->dimensionsI_.size(); i++) {
    ft_dims.push_back(i);
  }

  ft.fft((cuNDArray<cuFloatComplex>*)&tmp, &ft_dims); // TODO: fix FFT interface

  if (!accumulate) 
    cuNDA_clear<_complext>(out);

  dim3 blockDim(512,1,1);
  dim3 gridDim((unsigned int) ceil((double)idx_->get_number_of_elements()/blockDim.x), 1, 1 );
  sample_array_kernel<REAL><<< gridDim, blockDim >>>( tmp.get_data_ptr(), out->get_data_ptr(), idx_->get_data_ptr(),
						      in->get_number_of_elements(), idx_->get_number_of_elements(), this->ncoils_);
  cudaError_t err = cudaGetLastError();
  if( err != cudaSuccess ){
    std::cerr << "cgOperatorCartesianSense::mult_M : Unable to sample data: " << 
      cudaGetErrorString(err) << std::endl;
    return -1;
  }

  return 0;
}

template<class REAL, unsigned int D> int 
cgOperatorCartesianSense<REAL,D>::mult_MH(cuNDArray<_complext>* in, cuNDArray<_complext>* out, bool accumulate)
{
  if (!(out->dimensions_equal(&this->dimensionsI_)) || !(in->dimensions_equal(&this->dimensionsK_)) ) {
    std::cerr << "cgOperatorCartesianSense::mult_MH dimensions mismatch" << std::endl;
    return -1;
  }

  std::vector<unsigned int> tmp_dimensions = this->dimensionsI_;
  tmp_dimensions.push_back(this->ncoils_);

  cuNDArray<_complext> tmp;
  if (!tmp.create(&tmp_dimensions)) {
    std::cerr << "cgOperatorCartesianSense::mult_MH: Unable to create temp storage" << std::endl;
    return -1;
  }

  cuNDA_clear<_complext>(&tmp);

  dim3 blockDim(512,1,1);
  dim3 gridDim((unsigned int) ceil((double)idx_->get_number_of_elements()/blockDim.x), 1, 1 );
  insert_samples_kernel<REAL><<< gridDim, blockDim >>>( in->get_data_ptr(), tmp.get_data_ptr(),
							idx_->get_data_ptr(),out->get_number_of_elements(),
							idx_->get_number_of_elements(), this->ncoils_);
  
  cudaError_t err = cudaGetLastError();
  if( err != cudaSuccess ){
    std::cerr << "cgOperatorCartesianSense::mult_EM : Unable to insert samples into array: " << 
      cudaGetErrorString(err) << std::endl;
    return -1;
  }

  cuNDFFT ft;
  std::vector<unsigned int> ft_dims;
  for (unsigned int i = 0; i < this->dimensionsI_.size(); i++) {
    ft_dims.push_back(i);
  }

  ft.ifft((cuNDArray<cuFloatComplex>*)&tmp, &ft_dims); // TODO: fix FFT interface

  if (!accumulate) 
    cuNDA_clear<_complext>(out);
  
  if (mult_csm_conj_sum(&tmp,out) < 0) {
    std::cerr << "cgOperatorCartesianSense::mult_MH: Unable to multiply with conjugate of sensitivity maps and sum" << std::endl;
    return -1;
 
  }

  return 0;
}

//
// Instantiations
//

template class EXPORTGPUPMRI cgOperatorCartesianSense<float,2>;