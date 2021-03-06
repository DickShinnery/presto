/*
 * cuda_utils.h
 *
 *      Author: claidler Laidler
 *      e-mail: chris.laidler@gmail.com
 *
 *      This contains a number of basic functions for use with CUDA applications
 */

#ifndef CUDA_UTILS_H_
#define CUDA_UTILS_H_

#include <stdio.h>
#include <cuda.h>
#include <cufft.h>
#include <sys/time.h>
#include <cuda_runtime.h>
#include <cuda_runtime_api.h>

#include "cuda_accel.h"

#define BLACK     "\033[22;30m"
#define GREEN     "\033[22;31m"
#define MAGENTA   "\033[22;35m"
#define RESET     "\033[0m"

#define WARP_SIZE (32)

// Free a pointer and set value to zero
#define freeNull(pointer) { if (pointer) free ( pointer ); pointer = NULL; }
#define cudaFreeNull(pointer) { if (pointer) CUDA_SAFE_CALL(cudaFree(pointer), "Failed to free device memory."); pointer = NULL; }
#define cudaFreeHostNull(pointer) { if (pointer) CUDA_SAFE_CALL(cudaFreeHost(pointer), "Failed to free host memory."); pointer = NULL; }

// Defines for GPU Architecture types (using the SM version to determine the # of cores per SM)
typedef struct
{
    int SM; // 0xMm (hexadecimal notation), M = SM Major version, and m = SM minor version  ie 0x12 (18) is compute 1.2
    int value;
} SMVal;


//====================================== Inline functions ================================================//

const char* _cudaGetErrorEnum(cufftResult error);

//__device__ inline
//float warpReduceSum(float val)
//{
//  for (int offset = WARP_SIZE/2; offset > 0; offset /= 2)
//    val += __shfl_down_sync(0xffffffff, val, offset);
//
//  return val;
//}
//
//__device__ inline
//float blockReduceSum(float val, int lId, int wId)
//{
//  static __shared__ float shared[32]; // Shared mem for 32 partial sums
//
//  val = warpReduceSum(val);     // Each warp performs partial reduction
//
//  if (lId==0) shared[wId]=val;  // Write reduced value to shared memory
//
//  __syncthreads();              // Wait for all partial reductions
//
//  if (wId==0)
//  {
//    //read from shared memory only if that warp existed
//    val = ( lId < blockDim.x * blockDim.y / WARP_SIZE) ? shared[lId] : 0;
//
//    val = warpReduceSum(val); //Final reduce within first warp
//  }
//
//  return val;
//}

//==================================== Function Prototypes ===============================================//

inline int getValFromSMVer(int major, int minor, SMVal* vals);

/**
 * @brief printf a message iff compiled in debug mode
 *
 * @param format C string that contains a format string that follows the same specifications as format in <a href="http://www.cplusplus.com/printf">printf</a>
 * @return void
 **/
void debugMessage ( const char* format, ... );

void errMsg ( const char* format, ... );

ExternC void infoMSG ( int lev, int indent, const char* format, ... );

int detect_gdb_tree(void);

/**
 * @brief get free ram in bytes
 *
 * @return number of bytes of free RAM
 **/
ExternC size_t getFreeRamCU();

ExternC int optList(GSList *listptr, cuSearch* cuSrch);

ExternC void __cuSafeCall(cudaError_t cudaStat,    const char *file, const int line, const char* format, ...);
ExternC void __cufftSafeCall(cufftResult cudaStat, const char *file, const int line, const char* format, ...);
ExternC void __exit_directive(const char *file, const int line, const char *flag);
ExternC ACC_ERR_CODE __cuErrCall(cudaError_t cudaStat, const char *file, const int line, const char* format, ...);

/** Get the number of CUDA capable GPUS's
 */
ExternC int getGPUCount();

ExternC gpuInf* getGPU(gpuInf* gInf);

ExternC gpuInf* initGPU(int device, gpuInf* gInf);

ExternC void initGPUs(gpuSpecs* gSpec);

/** Print a nice list of CUDA capable device(s) with some details
 */
ExternC void listDevices();

/** Get GPU memory alignment in bytes  .
 *
 */
ExternC int getMemAlignment();

/** Get the stride (in number of elements) given a number of elements and the "block" size  .
 */
ExternC int getStride(int noEls, int elSz, int blockSz);

ExternC void streamSleep(cudaStream_t stream, long long int clock_count );

ExternC void queryEvents( cudaEvent_t   evnt, const char* msg );

ExternC void timeEvents( cudaEvent_t   start, cudaEvent_t   end, long long* timeSum, const char* msg );

#endif /* CUDA_UTILS_H_ */
