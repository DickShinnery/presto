// Automated testing SS: 16 16

#include <cufft.h>
#include <algorithm>
#include <omp.h>


#include <thrust/sort.h>
#include <thrust/device_vector.h>
#include <nvToolsExt.h>
#include <nvToolsExtCudaRt.h>


extern "C"
{
#define __float128 long double
#include "accel.h"
}

#include "cuda_accel.h"
#include "cuda_utils.h"
#include "cuda_accel_utils.h"

//extern "C"
//{
//#include "cuda_utils.h"
//}

// S(x) for small x
static __device__ double sn[6] =
{ -2.99181919401019853726E3, 7.08840045257738576863E5, -6.29741486205862506537E7, 2.54890880573376359104E9, -4.42979518059697779103E10, 3.18016297876567817986E11,};

static __device__ double sd[6] =
{ 2.81376268889994315696E2, 4.55847810806532581675E4, 5.17343888770096400730E6, 4.19320245898111231129E8, 2.24411795645340920940E10, 6.07366389490084639049E11,};

// C(x) for small x
static __device__ double cn[6] =
{ -4.98843114573573548651E-8, 9.50428062829859605134E-6, -6.45191435683965050962E-4, 1.88843319396703850064E-2, -2.05525900955013891793E-1, 9.99999999999999998822E-1,};

static __device__ double cd[7] =
{ 3.99982968972495980367E-12, 9.15439215774657478799E-10, 1.25001862479598821474E-7, 1.22262789024179030997E-5, 8.68029542941784300606E-4, 4.12142090722199792936E-2, 1.00000000000000000118E0,};

// Auxiliary function f(x)
static __device__ double fn[10] =
{ 4.21543555043677546506E-1, 1.43407919780758885261E-1, 1.15220955073585758835E-2, 3.45017939782574027900E-4, 4.63613749287867322088E-6, 3.05568983790257605827E-8, 1.02304514164907233465E-10, 1.72010743268161828879E-13, 1.34283276233062758925E-16, 3.76329711269987889006E-20,};

static __device__ double fd[10] =
{ 7.51586398353378947175E-1, 1.16888925859191382142E-1, 6.44051526508858611005E-3, 1.55934409164153020873E-4, 1.84627567348930545870E-6, 1.12699224763999035261E-8, 3.60140029589371370404E-11, 5.88754533621578410010E-14, 4.52001434074129701496E-17, 1.25443237090011264384E-20,};

// Auxiliary function g(x)
static __device__ double gn[11] =
{ 5.04442073643383265887E-1, 1.97102833525523411709E-1, 1.87648584092575249293E-2, 6.84079380915393090172E-4, 1.15138826111884280931E-5, 9.82852443688422223854E-8, 4.45344415861750144738E-10, 1.08268041139020870318E-12, 1.37555460633261799868E-15, 8.36354435630677421531E-19, 1.86958710162783235106E-22,};

static __device__ double gd[11] =
{ 1.47495759925128324529E0, 3.37748989120019970451E-1, 2.53603741420338795122E-2, 8.14679107184306179049E-4, 1.27545075667729118702E-5, 1.04314589657571990585E-7, 4.60680728146520428211E-10, 1.10273215066240270757E-12, 1.38796531259578871258E-15, 8.39158816283118707363E-19, 1.86958710162783236342E-22,};

/*
__device__ void acquire_semaphore(volatile int *lock)
{
  while (atomicCAS((int *) lock, 0, 1) != 0);
}

__device__ void release_semaphore(volatile int *lock)
{
 *lock = 0;
  __threadfence();
}
 */

/** Return the first value of 2^n >= x
 */
__host__ __device__ long long next2_to_n_cu(long long x)
{
  long long i = 1;

  while (i < x)
    i <<= 1;

  return i;
}

__device__ inline void swap(int & a, int & b)
{
  a = a ^ b;
  b = a ^ b;
  a = a ^ b;
}

__device__ inline void Comparator(float &valA, float &valB, uint dir)
{
  if ((valA > valB) == dir)
  {
    register float t;
    //swap(*(int*)&valA, *(int*)&valB );
    t = valA;
    valA = valB;
    valB = t;
  }
}

__device__ void bitonicSort(float *sData, uint arrayLength, int dir)
{
  const uint noBatch = ceilf(arrayLength / 2.0 / blockDim.x);    // Number of comparisons each thread must do
  uint idx;
  const uint max = arrayLength * 2;
  uint bIdx;// The thread position in the block
  uint hSz = 1;// half block size
  uint pos1, pos2, blk;
  uint len;// The distance between items to swap
  uint bach;// The batch we are processing

  for (uint size = 2; size < max; size <<= 1)
  {
    hSz = (size >> 1);

    __syncthreads();

    for (bach = 0; bach < noBatch; bach++)
    {
      idx = (threadIdx.x + bach * blockDim.x);

      bIdx = hSz - 1 - idx % hSz;
      blk = idx / hSz;

      len = size - 1 - bIdx * 2;
      pos1 = blk * size + bIdx;
      pos2 = pos1 + len;

      if (pos2 < arrayLength)
        Comparator(sData[pos1], sData[pos2], dir);
    }

    for (len = (hSz >>= 1); len > 0; len >>= 1)
    {
      hSz = (len << 1);

      __syncthreads();
      for (bach = 0; bach < noBatch; bach++)
      {
        idx = (threadIdx.x + bach * blockDim.x);

        bIdx = idx % len;
        blk = idx / len;

        pos1 = blk * hSz + bIdx;
        pos2 = pos1 + len;

        if (pos2 < arrayLength)
          Comparator(sData[pos1], sData[pos2], dir);
      }
    }
  }

  __syncthreads();
}

__device__ uint binarySearch(volatile float* sDataGlob, uint Start, uint End, float value)
{
  uint lower = Start;
  uint upper = End;
  uint mid = (End - Start) / 2;

  // continue searching while [imin,imax] is not empty
  while (upper > lower)
  {
    float ll = sDataGlob[lower];
    float uu = sDataGlob[upper];

    // calculate the midpoint for roughly equal partition
    mid = (upper + lower) / 2;
    float mm = sDataGlob[mid];

    if (mm < value)
      lower = mid + 1;
    else
      upper = mid - 1;
  }
  float ll = sDataGlob[lower];
  float uu = sDataGlob[upper];
  float mm = sDataGlob[mid];
  return lower;
}

/** in-place bitonic sort float array in shared memory
 * @param data A pointer to an shared memory array containing elements to be sorted.
 * @param arrayLength The number of elements in the array
 * @param trdId the index of the calling thread (1 thread for 2 items in data)
 * @param noThread The number of thread that are sorting this data
 * @param dir direction to sort data ( 1 -> smallest to largest AND -1 -> largest to smallest )
 *
 * This is an in-place bitonic sort.
 * This is very fast for small numbers of items, ie; when they can all fit in shared memory, or generally are less that 1K or 2K
 *
 * It has a constant performance of \f$ O\left(n\ \log^2 n \right)\f$ where n is the number of items to be sorted.
 * It only works on shared memory as it requires synchronisation.
 *
 * Each thread counts for to items in the array, as each thread performs comparisons between to elements.
 * Generally there is ~48.0 KBytes of shared memory, thus could sort up to 12288 items. However there is a
 * maximum of 1024 thread per block, thus if there are more that 2048 threads each thread must do multiple comparisons at
 * each step. These are refereed to as batches.
 *
 */
__device__ void bitonicSort(float *data, const uint arrayLength, const uint trdId, const uint noThread, const int dir = 1)
{
  const uint noBatch = ceilf(arrayLength / 2.0 / noThread);     // Number of comparisons each thread must do
  uint idx;                               // The index including batch adjustment
  const uint max = arrayLength * 2;       // The maximum distance a thread could compare
  uint bIdx;                              // The thread position in the block
  uint hSz = 1;                           // half block size
  uint pos1, pos2, blk;                   // index of points to be compared
  uint len;                               // The distance between items to swap
  uint bach;                              // The batch we are processing
  uint shift = 32;                        // Amount to bitshift by to calculate remainders
  uint shift2;
  uint hsl1;

  // Incrementally sort blocks of 2 then 4 then 8 ... items
  for (uint size = 2; size < max; size <<= 1, shift--)
  {
    hSz = (size >> 1);
    hsl1 = hSz - 1;

    __syncthreads();

    // Bitonic sort, two Bitonic sorted list into Bitonic list
    for (bach = 0; bach < noBatch; bach++)
    {
      idx = (trdId + bach * noThread);

      //bIdx = hSz - 1 - idx % hSz;
      //bIdx = hsl1 - (idx << shift) >> shift;  // My method
      bIdx = hsl1 - idx & (hSz - 1);// x mod y == x & (y-1), where y is 2^n.

      blk = idx / hSz;

      len = size - 1 - bIdx * 2;
      pos1 = blk * size + bIdx;
      pos2 = pos1 + len;

      if (pos2 < arrayLength)
        Comparator(data[pos1], data[pos2], dir);
    }

    // Bitonic Merge
    for (len = (hSz >>= 1), shift2 = shift + 1; len > 0; len >>= 1, shift2++)
    {
      hSz = (len << 1);

      __syncthreads();
      for (bach = 0; bach < noBatch; bach++)
      {
        idx = (trdId + bach * noThread);

        //bIdx  = idx % len;
        //bIdx = (idx << shift2) >> shift2;
        bIdx = idx & (len - 1);// x mod y == x & (y-1), where y is 2^n.

        blk = idx / len;

        pos1 = blk * hSz + bIdx;
        pos2 = pos1 + len;

        if (pos2 < arrayLength)
          Comparator(data[pos1], data[pos2], dir);
      }
    }
  }

  __syncthreads();  // Ensure all data is sorted before we return
}

__global__ void normAndSpreadBlks(cHarmList data, iHarmList len, iHarmList widths)
{
  int blkId = blockIdx.y  * NAS_DIMY  + blockIdx.x;        // The flat ID of this block in the grid
  int trdId = threadIdx.y * NAS_DIMX  + threadIdx.x;       // The flat ID of this thread in the block

  fcomplexcu* inp   = data.val[blkId];
  uint arrayLength  = len.val[blkId];

  extern __shared__ float s[];
  float* sData  = &s[0];              // Shared memory to do the median calculation
  float* factor = &s[arrayLength+1];  // Shared memory factor for normalisation

  bool D2 = false;

  // There are a maximum of 1024 threads in a block
  // We can store 12288 floats in shared memory, thus each thread could do 12 batches of work
  // Number of threads = arrayLength/2.0 -> each thread handles 2 values at a time
  uint noBatch = ceil((float)arrayLength / (float)( NAS_NTRD * 2 ) );// Number of comparisons each thread must do
  uint idx;
  float2 bob;

  float2 hld[BS_MAX / NAS_NTRD];      // A temporary store to hole values read
  float2 *ii = (float2*) &inp[0].r;   // The data in memory

  // Load data into shared memory
  if (D2)
  {
    for (int i = 0; i < noBatch * 2; i++)
    {
      idx = trdId + NAS_NTRD * i;
      if (idx < arrayLength )
      {
        bob = ii[idx * ACCEL_NUMBETWEEN];
        sData[idx] = bob.x * bob.x + bob.y * bob.y;
      }
    }
    __syncthreads();  // Make sure we have read all the memory before we starts sorting
  }
  else
  {
    // read the data from memory, store in temporary 'hld' and store powers in shared memory
    for (int i = 0; i < noBatch * 2; i++)
    {
      idx = trdId + NAS_NTRD * i;
      if (idx < arrayLength )
      {
        bob = ii[idx];

        // Keep values
        hld[i] = bob;

        // Store powers in shared memory
        sData[idx] = bob.x * bob.x + bob.y * bob.y;
      }
    }

    // Now set the entire block of input on the device memory to 0
    {
      // Note the latency of this write will mostly be absorbed by the sort
      // It could be done with the final write back but this works as fats

      __syncthreads(); // Make sure we have read from memory before we zero it and make sure shared memory is full

      uint width = widths.val[blkId];
      uint noBatch2 = ceilf(width * 2 / NAS_NTRD);// Number of memset's each thread must do
      float *data = (float*) inp;

      for (int i = 0; i < noBatch2; i++)
      {
        idx = trdId + NAS_NTRD * i;
        if (idx < width * 2)
        {
          data[idx] = 0;
        }
      }
    }
  }

  bitonicSort(sData, arrayLength, trdId, NAS_NTRD);

  // Calculate the normalisation factor
  if ( trdId == 0 )
  {
    idx = arrayLength / 2.0;
    float medainl = -1;

    if ((arrayLength & 1))   // odd
    {
      medainl = sData[idx];
    }
    else                        //even
    {
      // mean
      //medainl = (sData[idx-1] + sData[idx])/2.0;

      // lower
      medainl = sData[idx - 1];

      // upper
      //medainl = sData[idx];
    }
    *factor = 1.0 / sqrt(medainl / log(2.0));
  }
  __syncthreads();  // Make sure all threads can see factor

  // Normalise complex numbers and write back with spread
  if (D2)
  {
    /*
    for (int i = 0; i < noBatch * 2; i++)
    {
      idx = trdId + NAS_NTRD * i;
      if (idx < arrayLength)
      {
        ii[idx * ACCEL_NUMBETWEEN].x *= *factor;
        ii[idx * ACCEL_NUMBETWEEN].y *= *factor;
      }
    }
     */
  }
  else
  {
    for (int i = 0; i < noBatch * 2; i++)
    {
      idx = trdId + NAS_NTRD * i;
      if (idx < arrayLength)
      {
        // Normalise
        hld[i].x *= *factor;
        hld[i].y *= *factor;
        //hld[0].x *= factor;
        //hld[0].y *= factor;

        // Write back to memory with spread
        ii[idx * ACCEL_NUMBETWEEN] = hld[i];
      }
    }
  }

  /*
   //uint ix = blockIdx.x * blockDim.x + threadIdx.x;
   arrayLength = widths[blkId];

   uint noBatch = ceilf(arrayLength*2 / NAS_NTRD);    // Number of comparisons each thread must do
   for (int i = 0; i < noBatch ; i++)
   {
   idx = trdId + NAS_NTRD * i;
   float n = 0;

   // This assumes ACCEL_NUMBETWEEN = 2!
   if ( idx & 2 )
   {
   n = 0;
   }
   else
   {
   if (idx & 1)
   {
   n =

   }
   }
   else


   bIdx = idx & (len-1) ;             // x mod y == x & (y-1), where y is 2^n.



   //uint mx1 = arrayLength / 2;
   if (ix < arrayLength)
   {
   if (ix < arrayLength)
   {
   dataOut[ix * ACCEL_NUMBETWEEN].r = data[ix].r * (*median);
   dataOut[ix * ACCEL_NUMBETWEEN].i = data[ix].i * (*median);
   }
   else
   {
   dataOut[ix * ACCEL_NUMBETWEEN].r = 0;
   dataOut[ix * ACCEL_NUMBETWEEN].i = 0;
   }
   dataOut[ix * ACCEL_NUMBETWEEN + 1].r = 0;
   dataOut[ix * ACCEL_NUMBETWEEN + 1].i = 0;
   }
   }
   */

  /*
   if (true)
   {
   float *ii = &inp[0].r;
   // Load data into shared memory
   for (int i = 0; i < noBatch * 4; i++)
   {
   idx = trdId + NAS_NTRD * i;
   if (idx < arrayLength * 2)
   {
   //inp[ idx ].r *= factor;
   //inp[ idx ].i *= factor;
   ii[idx] *= factor;
   }
   }
   }
   else
   {
   // Load data into shared memory
   for (int i = 0; i < noBatch * 2; i++)
   {
   idx = trdId + NAS_NTRD * i;
   if (idx < arrayLength)
   {
   inp[idx].r *= factor;
   inp[idx].i *= factor;
   //ii[idx] *= factor ;
   }
   }
   }
   */
}

__global__ void normAndSpreadBlksDevice(cHarmList readData, cHarmList writeData, iHarmList len, iHarmList widths)
{
  int blkId = blockIdx.y  * gridDim.x  + blockIdx.x;        // The flat ID of this block in the grid
  int trdId = threadIdx.y * blockDim.x + threadIdx.x;       // The flat ID of this thread in the block

  fcomplexcu* inp     = readData.val[blkId];
  //fcomplexcu* output  = readData.val[blkId];
  uint arrayLength    = len.val[blkId];

  // Set up shared memory
  extern __shared__ float s[];
  float* sData        = &s[0];              // Shared memory to do the median calculation
  float* factor       = &s[arrayLength+1];  // Shared memory factor for normalisation

  // There are a maximum of 1024 threads in a block
  // We can store 12288 floats in shared memory, thus each thread could do 12 batches of work
  // Number of threads = arrayLength/2.0 -> each thread handles 2 values at a time
  uint noBatch = ceil((float)arrayLength / (float)( NAS_NTRD * 2 ) );// Number of comparisons each thread must do
  uint idx;
  float2 bob;

  float2 hld[ BS_MAX / NAS_NTRD ];      // A temporary store to hole values read
  float2 *ii = (float2*) &inp[0].r;     // The data in memory

  // read the data from memory, store in temporary 'hld' and store powers in shared memory
  for (int i = 0; i < noBatch * 2; i++)
  {
    idx = trdId + NAS_NTRD * i;
    if (idx < arrayLength )
    {
      bob = ii[idx];

      // Keep values
      hld[i] = bob;

      // Store powers in shared memory
      sData[idx] = bob.x * bob.x + bob.y * bob.y;
    }
  }

  // Now set the entire block of device memory to 0
  {
    // Note the latency of this write will mostly be absorbed by the sort
    // It could be done with the final write back but this works as fats
    uint width = widths.val[blkId];
    uint noBatch2 = ceilf(width * 2 / NAS_NTRD);// Number of memset's each thread must do
    float *data = (float*) writeData.val[0];

    for (int i = 0; i < noBatch2; i++)
    {
      idx = trdId + NAS_NTRD * i;
      if (idx < width * 2)
      {
        data[idx] = 0;
      }
    }
  }

  bitonicSort(sData, arrayLength, trdId, NAS_NTRD);

  // Calculate the normalisation factor
  if (trdId == 0)
  {
    idx = arrayLength / 2.0;
    float medainl = -1;

    if ((arrayLength & 1))   // odd
    {
      medainl = sData[idx];
    }
    else                        //even
    {
      // mean
      //medainl = (sData[idx-1] + sData[idx])/2.0;

      // lower
      medainl = sData[idx - 1];

      // upper
      //medainl = sData[idx];
    }
    *factor = 1.0 / sqrt(medainl / log(2.0));
  }
  __syncthreads();  // Make sure all threads can see factor

  // Normalise complex numbers and write back with spread
  for (int i = 0; i < noBatch * 2; i++)
  {
    idx = trdId + NAS_NTRD * i;
    if (idx < arrayLength)
    {
      // Normalise
      hld[i].x *= *factor;
      hld[i].y *= *factor;

      // Write back to memory with spread
      ii[idx * ACCEL_NUMBETWEEN] = hld[i];
    }
  }
}

__global__ void median1Block(const float *data, uint arrayLength, float *median, uint noBatch)
{

  //const int trdId = threadIdx.y * blockDim.x + threadIdx.x; // The flat ID of this thread in the block
  //int noThread = blockDim.x * blockDim.y;                 // The number of threads in a block
  //const int noThread = 1024;


  __shared__ float sData[BS_MAX];                   // Shared memory to do the calculation

  // There are a maximum of 1024 threads in a block
  // We can store 12288 floats in shared memory, thus each thread could to 12 batches of work
  // Number of threads = arrayLength/2.0 -> each thread handles 2 values at a time

  //uint noBatch = ceilf(arrayLength / 2.0 / blockDim.x);    // Number of comparisons each thread must do
  //   uint x;
  uint idx;
  int dir = 1;

  //idx = threadIdx.x;
  //data[idx] = noBatch;

  // Load data into shared memory
  for (int i = 0; i < noBatch * 2; i++)
  {
    idx = threadIdx.x + blockDim.x * i;

    if (idx < arrayLength)
    {
      sData[idx] = data[idx];
    }
  }

  //__syncthreads();

  //bitonicSort(sData, arrayLength, 1);

  uint max = arrayLength * 2;
  uint bIdx;// The thread position in the block
  uint hSz = 1;// half block size
  uint pos1, pos2, blk;
  uint len;// The distance between items to swap
  //uint bach;                      // The batch we are processing

  for (uint size = 2; size < max; size <<= 1)
  {
    hSz = (size >> 1);

    __syncthreads();
    for (int bach = 0; bach < noBatch; bach++)
    {
      idx = (threadIdx.x + bach * blockDim.x);

      bIdx = hSz - 1 - idx % hSz;
      blk = idx / hSz;

      len = size - 1 - bIdx * 2;
      pos1 = blk * size + bIdx;
      pos2 = pos1 + len;

      if (pos2 < arrayLength)
        Comparator(sData[pos1], sData[pos2], dir);
    }

    for (len = (hSz >>= 1); len > 0; len >>= 1)
    {
      hSz = (len << 1);
      __syncthreads();

      for (int bach = 0; bach < noBatch; bach++)
      {
        idx = (threadIdx.x + bach * blockDim.x);

        bIdx = idx % len;
        blk = idx / len;

        pos1 = blk * hSz + bIdx;
        pos2 = pos1 + len;

        if (pos2 < arrayLength)
          Comparator(sData[pos1], sData[pos2], dir);
      }
    }
  }

  __syncthreads();

  if (threadIdx.x == 0)
  {

    idx = arrayLength / 2.0;
    double medainl = -1;

    if ((arrayLength & 1))   // odd
    {
      medainl = sData[idx];
    }
    else                        //even
    {
      // mean
      //medainl = (sData[idx - 1] + sData[idx]) / 2.0;

      // lower
      medainl = sData[idx-1];

      // upper
      //medainl = sData[idx];
    }

    medainl = 1.0 / sqrt(medainl / log(2.0));
    *median = medainl;
  }
}

__global__ void sortNBlock(float *data, uint arrayLength, float *output, int dir = 1)
{
  __shared__ float sData[BS_MAX];                           // Shared memory to do the calculation

  //float noB = arrayLength / 2.0 / (blockDim.x * gridDim.x);
  uint noBatch = ceilf(arrayLength / 2.0 / (blockDim.x * gridDim.x));// The number of comparisons each thread must perform at each step
  uint bachLen = noBatch * blockDim.x * 2;// Number of keys sorted by a thread block (each thread counts for two numbers)

  uint gIdx;// Global data index
  uint bIdx;// Thread block index
  uint bblen = bachLen;

  // Load data into shared memory
  for (int i = 0; i < noBatch * 2; i++)
  {
    bIdx = threadIdx.x + blockDim.x * i;
    gIdx = bIdx + blockIdx.x * bachLen;

    if (gIdx < arrayLength)
      sData[bIdx] = data[gIdx];
  }

  // Set bachLen for last block
  if ((gridDim.x - 1) == blockIdx.x)
    bachLen = arrayLength - bachLen * blockIdx.x;

  bitonicSort(sData, bachLen, dir);

  // Load data back into main memory
  for (int i = 0; i < noBatch * 2; i++)
  {
    bIdx = threadIdx.x + blockDim.x * i;
    gIdx = bIdx + blockIdx.x * bblen;

    if (gIdx < arrayLength)
      data[gIdx] = sData[bIdx];
  }

  if (threadIdx.x == 0)
  {
    float max = sData[bachLen - 1];
    float min = sData[0];
    float median = sData[(bachLen - 1) / 2];

    output[blockIdx.x] = median;
    output += gridDim.x;
    output[blockIdx.x] = min;
    output += gridDim.x;
    output[blockIdx.x] = max;

    //printf("Block %03i found %14.3f\n                %14.3f\n                %14.3f\n", blockIdx.x, max, min, median);
  }

}

__global__ void selectMedianCands(float *data, uint arrayLength, float *output, int dir = 1)
{
  __shared__ uint dist;
  __shared__ uint lower;
  __shared__ uint upper;

  __shared__ float sData[BS_MAX];             // Shared memory to do the calculation

  //float noB = arrayLength / 2.0 / (blockDim.x * gridDim.x);
  uint noBatch = ceilf(arrayLength / 2.0 / (blockDim.x * gridDim.x));// The number of comparisons each thread must perform at each step
  uint bachLen = noBatch * blockDim.x * 2;// Number of keys sorted by a thread block (each thread counts for two numbers)
  uint bblen = bachLen;

  uint gIdx;
  uint bIdx;

  //data += blockIdx.x*bachLen ;

  // Load data into shared memory
  for (int i = 0; i < noBatch * 2; i++)
  {
    bIdx = threadIdx.x + blockDim.x * i;
    gIdx = blockIdx.x * bblen + bIdx;

    if (gIdx < arrayLength)
      sData[bIdx] = data[gIdx];
  }

  if ((gridDim.x - 1) == blockIdx.x)
    bachLen = arrayLength - bachLen * blockIdx.x;

  __syncthreads();

  float max;
  float min;

  if (threadIdx.x == 0)
  {
    max = output[0];
    min = output[0];
    for (int i = 1; i < gridDim.x; i++)
    {
      if (output[i] < min)
        min = output[i];

      if (output[i] > max)
        max = output[i];

    }
    lower = binarySearch(sData, 0, bachLen - 1, min);
    upper = binarySearch(sData, 0, bachLen - 1, max);
    dist = upper - lower;

    //printf("Block %02i is %04i  min %10.2f  max %10.2f  %05i %05i\n", blockIdx.x, dist, min, max, lower, upper);

    output += gridDim.x * 3;// Skip previous values (median min max)

    // Number of items in this list
    output[blockIdx.x] = dist;
    output += gridDim.x;

    // Number of items below the list
    output[blockIdx.x] = lower;
    output += gridDim.x;

    // Number of items above the list
    output[blockIdx.x] = upper;
  }

  __syncthreads();

  // Load data into memory
  for (int i = 0; i < noBatch * 2; i++)
  {
    bIdx = threadIdx.x + blockDim.x * i;
    gIdx = blockIdx.x * bblen + bIdx;

    if (gIdx < arrayLength && bIdx >= lower && bIdx <= upper)
      data[gIdx - lower] = sData[bIdx];
  }
}

__global__ void medFromMedians(float *data, uint arrayLength, float *output, int noSections, float *median, int dir = 1)
{
  __shared__ uint dist[100];
  __shared__ uint lower[100];
  //__shared__ uint upper[100];

  __shared__ float sData[BS_MAX];// Shared memory to do the calculation

  __shared__ uint length;

  uint noBatch = ceilf(arrayLength / 2.0 / (blockDim.x * noSections));// The number of comparisons each thread must perform at each step
  uint bachLen = noBatch * blockDim.x * 2;// Number of keys sorted by a thread block (each thread counts for two numbers)
  //uint bblen = bachLen;

  //uint noBatch  = 1;
  //uint bachLen  = arrayLength / blockDim.x*2 / noSections;         // Number of keys sorted by a thread block (each thread counts for two numbers)

  uint gIdx;
  uint bIdx;

  output += noSections * 3;// skip forward to output

  if (threadIdx.x == 0)
  {
    dist[0] = 0;
    int noPoints = 0;
    for (int i = 0; i < noSections; i++)
    {

      dist[i] = noPoints;
      noPoints += output[i];

      //printf("Block %02i is %i\n", i, output[i] );

      // Lower
      lower[i] = bachLen * i + output[noSections + i];

      //output +=  noSections;
      //upper[i] = bachLen * i + output[noSections * 2 + i];
    }
    length = noPoints;

    if (noPoints >= BS_MAX)
      printf("ERROR: error in CUDA finding meadian, number of points wont fit in Shared Memeor!\n");
  }

  __syncthreads();

  //float bb = length / blockDim.x / 2.0;
  noBatch = ceilf(length / blockDim.x / 2.0);

  //data += blockIdx.x*bachLen ;

  // Load data into shared memory
  for (int i = 0; i < noBatch * 2; i++)
  {
    bIdx = threadIdx.x + blockDim.x * i;
    gIdx = blockIdx.x * bachLen + bIdx;

    int read = -1;
    int write = -1;

    for (int i = 0; i < noSections; i++)
    {
      if (gIdx >= dist[i] && gIdx < dist[i + 1])
      {
        read = lower[i] + gIdx - dist[i];
        write = gIdx;
      }
    }

    if (read > 0)
    {
      sData[write] = data[read];
    }
  }

  __syncthreads();

  bitonicSort(sData, length, dir);

  __syncthreads();

  if (threadIdx.x == 0 && blockIdx.x == 0)
  {
    int below = 0;
    for (int i = 0; i < noSections; i++)
    {
      below += output[noSections + i];
    }

    int medianPosGlobal = (arrayLength) / 2;

    int medianPos = (arrayLength) / 2 - below;

    float medainl;

    if ((medianPosGlobal & 1))   // odd
    {
      medainl = sData[medianPos];
    }
    else                        //even
    {
      // mean
      medainl = (sData[medianPos - 1] + sData[medianPos]) / 2.0;

      // lower
      //medainl = sData[idx-1];

      // upper
      //medainl = sData[idx];
    }
    *median = 1.0 / sqrt(medainl / log(2.0));
    //printf("Median is normalization factor is %15.10f  median:%f\n",*median, medainl );
  }
}

__global__ void normAndSpread(fcomplexcu *data, uint arrayLength, fcomplexcu *dataOut, uint maxSpread)
{
  __shared__ float sData[BS_MAX];                           // Shared memory to do the calculation
  __shared__ float median;// Shared memory to do the calculation

  //float noB = arrayLength / 2.0 / (blockDim.x * gridDim.x);
  const uint noBatch = ceilf(arrayLength / 2.0 / (blockDim.x * gridDim.x));// The number of comparisons each thread must perform at each step
  const uint bachLen = noBatch * blockDim.x * 2;// Number of keys sorted by a thread block (each thread counts for two numbers)

  uint gIdx;// Global data index
  uint bIdx;// Thread block index
  //uint bblen = bachLen;

  const uint mx1 = maxSpread / 2;

  // Load data into shared memory
  for (int i = 0; i < noBatch * 2; i++)
  {
    bIdx = threadIdx.x + blockDim.x * i;
    gIdx = bIdx + blockIdx.x * bachLen;

    if (gIdx < arrayLength)
    {
      sData[bIdx] = data[bIdx].r * data[bIdx].r + data[bIdx].i * data[bIdx].i;

      //float r = data[bIdx].r;
      //float i = data[bIdx].i;
      //sData[bIdx] = r*r + i*i ;
    }
  }

  // Sort in shared memory
  bitonicSort(sData, arrayLength, 1);

  // Find median in sorted data
  if (threadIdx.x == 0)
  {
    bIdx = arrayLength / 2.0;
    float medainl = -1;

    if ((arrayLength & 1))   // odd
    {
      medainl = sData[bIdx];
    }
    else                        //even
    {
      // mean
      medainl = (sData[bIdx - 1] + sData[bIdx]) / 2.0;

      // lower
      //medainl = sData[idx-1];

      // upper
      //medainl = sData[idx];
    }

    median = 1.0 / sqrt(medainl / logf(2.0));
  }

  __syncthreads();

  // Copy back to main memory
  for (int i = 0; i < noBatch * 2; i++)
  {
    bIdx = threadIdx.x + blockDim.x * i;
    gIdx = bIdx + blockIdx.x * bachLen;
    if (gIdx < mx1)
    {
      if (gIdx < arrayLength)
      {
        dataOut[gIdx * ACCEL_NUMBETWEEN].r = data[gIdx].r * median;
        dataOut[gIdx * ACCEL_NUMBETWEEN].i = data[gIdx].i * median;
      }
      else
      {
        dataOut[gIdx * ACCEL_NUMBETWEEN].r = 0;
        dataOut[gIdx * ACCEL_NUMBETWEEN].i = 0;
      }
      dataOut[gIdx * ACCEL_NUMBETWEEN + 1].r = 0;
      dataOut[gIdx * ACCEL_NUMBETWEEN + 1].i = 0;
    }
  }
}

__global__ void calculatePowers(fcomplexcu *data, float* powers, uint arrayLength)
{
  uint ix = blockIdx.x * blockDim.x+ threadIdx.x;
  if (ix < arrayLength)
  {
    float r = data[ix].r;
    float i = data[ix].i;
    powers[ix] = r * r + i * i;
  }
}

__global__ void devideAndSpreadFFT(fcomplexcu *data, uint arrayLength, fcomplexcu *dataOut, uint maxSpread, float *median)
{
  uint ix = blockIdx.x * blockDim.x + threadIdx.x;
  uint mx1 = maxSpread / 2;
  if (ix < mx1)
  {
    if (ix < arrayLength)
    {
      dataOut[ix * ACCEL_NUMBETWEEN].r = data[ix].r * (*median);
      dataOut[ix * ACCEL_NUMBETWEEN].i = data[ix].i * (*median);
    }
    else
    {
      dataOut[ix * ACCEL_NUMBETWEEN].r = 0;
      dataOut[ix * ACCEL_NUMBETWEEN].i = 0;
    }
    dataOut[ix * ACCEL_NUMBETWEEN + 1].r = 0;
    dataOut[ix * ACCEL_NUMBETWEEN + 1].i = 0;
  }
}

__global__ void chopAndpower(fcomplexcu *ffdot, uint width, uint strideFfdot, uint height, float *ffdotPowers, uint stridePowers, uint chopBefore, uint length)
{
  uint pix = blockIdx.x * blockDim.x + threadIdx.x;
  uint piy = blockIdx.y * blockDim.y + threadIdx.y;

  if (pix < length && piy < height)
  {
    uint fidx = piy * strideFfdot + pix + chopBefore;
    uint pidx = piy * stridePowers + pix;

    fcomplexcu cmp = ffdot[fidx];

    ffdotPowers[pidx] = cmp.r * cmp.r + cmp.i * cmp.i;

    //    ffdotPowers[pidx] = 0;
  }
}

__global__ void sumPlains(float* fund, int fWidth, int fStride, int fHeight, float* sub, int sWidth, int sStride, int sHeight, float frac, float fRlow, float fZlow, float sRlow, float sZlow)
{
  //__shared__ int indsX[ACCEL_USELEN];
  //__shared__ int indsY[ACCEL_USELEN];

  int ix = (blockIdx.x * blockDim.x + threadIdx.x);
  int iy = (blockIdx.y * blockDim.y + threadIdx.y);

  //int idx = iy * fStride + iy;

  //int bidx;
  int thredsinBlock = (blockDim.x * blockDim.y);
  int batches = ceilf(fWidth / (float) thredsinBlock);

  /*
   for ( int i = 0; i < batches; i++ )
   {
   bidx = i*thredsinBlock + threadIdx.y*blockDim.x + threadIdx.x;

   if ( bidx < fWidth )
   {
   int rr = fRlow + bidx * ACCEL_DR;
   int subr = calc_required_r_gpu(frac, rr);
   indsX[bidx] = index_from_r(subr, sRlow);
   }

   if ( bidx < fHeight )
   {
   int zz = fZlow + bidx * ACCEL_DZ;
   int subz  = calc_required_z(frac, zz);
   indsY[bidx] = index_from_z(subz, sZlow);
   }
   }
   __syncthreads();
   */

  if (ix < fWidth && iy < fHeight)
  {
    int rr = fRlow + ix * ACCEL_DR;
    int subr = calc_required_r_gpu(frac, rr);
    int isx = index_from_r(subr, sRlow);

    //int zz    = fZlow + (fHeight-1-iy) * ACCEL_DZ;
    int zz = fZlow + iy * ACCEL_DZ;
    int subz = calc_required_z(frac, zz);
    int isy = index_from_z(subz, sZlow);

    fund[iy * fStride + ix] += sub[isy * sStride + isx];
  }
}

/*
__global__ void resetCount()
{
  can_count_total += g_canCount;
  g_canCount = 0;
  g_canCount_aut = 0;
  g_canSem = SEMFREE;
  g_max = 0;
}
 */

/*
__global__ void printCount()
{
  if ( g_canCount )
    printf("\n                                     Search found %05i candidates. \n", g_canCount);
}
 */

__global__ void printfData(float* data, int nX, int nY, int stride, int sX = 0, int sY = 0)
{
  //printf("\n");
  for (int x = 0; x < nX; x++)
  {
    printf("---------");
  }
  printf("\n");
  for (int y = 0; y < nY; y++)
  {
    for (int x = 0; x < nX; x++)
    {
      printf("%8.4f ",data[ (y+sY)*stride + sX+ x ]);
    }
    printf("\n");
  }
  for (int x = 0; x < nX; x++)
  {
    printf("---------");
  }
  printf("\n");
}

__device__ double polevl(double x, double *p, int N)
{
  double ans;
  int i;
  //double *p;
  //p = coef;

  ans = *p++;
  i = N;

  do
    ans = ans * x + *p++;
  while (--i);

  return (ans);
}

__device__ double p1evl(double x, double *p, int N)
{
  double ans;
  //double *p;
  int i;

  //p = coef;
  ans = x + *p++;
  i = N - 1;

  do
    ans = ans * x + *p++;
  while (--i);

  return (ans);
}

__device__ int fresnl(double xxa, double *ssa, double *cca)
{
  double f, g, cc, ss, c, s, t, u;
  double x, x2;

  x = fabs(xxa);
  x2 = x * x;
  if (x2 < 2.5625) {
    t = x2 * x2;
    ss = x * x2 * polevl(t, sn, 5) / p1evl(t, sd, 6);
    cc = x * polevl(t, cn, 5) / polevl(t, cd, 6);
    goto done;
  }
  if (x > 36974.0) {
    cc = 0.5;
    ss = 0.5;
    goto done;
  }
  /* Auxiliary functions for large argument  */
  x2 = x * x;
  t = PI * x2;
  u = 1.0 / (t * t);
  t = 1.0 / t;
  f = 1.0 - u * polevl(u, fn, 9) / p1evl(u, fd, 10);
  g = t * polevl(u, gn, 10) / p1evl(u, gd, 11);
  t = PIBYTWO * x2;
  c = cos(t);
  s = sin(t);
  t = PI * x;
  cc = 0.5 + (f * s - g * c) / t;
  ss = 0.5 - (f * c + g * s) / t;

  done:

  if (xxa < 0.0) {
    cc = -cc;
    ss = -ss;
  }
  *cca = cc;
  *ssa = ss;
  return (0);
}

__device__ int z_resp_halfwidth(double z)
{
  int m;

  z = fabs(z);

  m = (long) (z * (0.00089 * z + 0.3131) + NUMFINTBINS);
  m = (m < NUMFINTBINS) ? NUMFINTBINS : m;

  // Prevent the equation from blowing up in large z cases

  if (z > 100 && m > 0.6 * z)
    m = 0.6 * z;

  return m;
}

/** Generate a complex response function for Fourier interpolation.
 *
 * This is a CUDA "copy" of gen_r_response in responce.c
 *
 * @param kx            The x index of the value in the kernel
 * @param roffset       Is the offset in Fourier bins for the full response (i.e. At this point, the response would equal 1.0)
 * @param numbetween    Is the number of points to interpolate between each standard FFT bin. (i.e. 'numbetween' = 2 = interbins, this is the standard)
 * @param numkern       Is the number of complex points that the kernel will contain.
 * @param rr            A pointer to the real part of the complex response for kx
 * @param ri            A pointer to the imaginary part of the complex response for kx
 */
__device__ inline void gen_r_response(int kx, double roffset, float numbetween, int numkern, float* rr, float* ri)
{
  int ii;
  double tmp, sinc, s, c, alpha, beta, delta, startr, r;

  startr = PI * (numkern / (double) (2 * numbetween));
  delta = -PI / numbetween;
  tmp = sin(0.5 * delta);
  alpha = -2.0 * tmp * tmp;
  beta = sin(delta);

  c = cos(startr);
  s = sin(startr);

  r = startr + kx * delta;

  if (kx == numkern / 2)
  {
    // Correct for divide by zero when the roffset is close to zero
    *rr = 1 - 6.579736267392905746 * (tmp = roffset * roffset);
    *ri = roffset * (PI - 10.335425560099940058 * tmp);
  }
  else
  {
    // TODO: Fix this!
    // I am recursing in the kernel o0
    // I just haven't had the time to calculate this per thread calculation
    // But it is only called once, so not to critical if it is inefficient
    for (ii = 0, r = startr; ii <= kx; ii++, r += delta)
    {
      if (r == 0.0)
        sinc = 1.0;
      else
        sinc = s / r;

      *rr = c * sinc;
      *ri = s * sinc;
      c = alpha * (tmp = c) - beta * s + c;
      s = alpha * s + beta * tmp + s;
    }
  }
}

/** Generate the complex response value for Fourier f-dot interpolation.
 *
 * This is based on gen_z_response in responce.c
 *
 * @param kx            The x index of the value in the kernel
 * @param z             The Fourier Frequency derivative (# of bins the signal smears over during the observation)
 * @param absz          Is the absolute value of z
 * @param roffset       Is the offset in Fourier bins for the full response (i.e. At this point, the response would equal 1.0)
 * @param numbetween    Is the number of points to interpolate between each standard FFT bin. (i.e. 'numbetween' = 2 = interbins, this is the standard)
 * @param numkern       Is the number of complex points that the kernel will contain.
 * @param rr            A pointer to the real part of the complex response for kx
 * @param ri            A pointer to the imaginary part of the complex response for kx
 */
__device__ inline void gen_z_response (int rx, float z,  double absz, float numbetween, int numkern, float* rr, float* ri)
{
  int signz;
  double zd, r, xx, yy, zz, startr, startroffset;
  double fressy, frescy, fressz, frescz, tmprl, tmpim;
  double s, c, pibyz, cons, delta;

  startr        = 0 - (0.5 * z);
  startroffset  = (startr < 0) ? 1.0 + modf(startr, &tmprl) : modf(startr, &tmprl);

  if (rx == numkern / 2.0 && startroffset < 1E-3 && absz < 1E-3)
  {
    double nr, ni;

    zz      = z * z;
    xx      = startroffset * startroffset;
    nr      = 1.0 - 0.16449340668482264365 * zz;
    ni      = -0.5235987755982988731 * z;
    nr      += startroffset * 1.6449340668482264365 * z;
    ni      += startroffset * (PI - 0.5167712780049970029 * zz);
    nr      += xx * (-6.579736267392905746 + 0.9277056288952613070 * zz);
    ni      += xx * (3.1006276680299820175 * z);

    *rr     = nr;
    *ri     = ni;
  }
  else
  {
    signz   = (z < 0.0) ? -1 : 1;
    zd      = signz * (double) SQRT2 / sqrt(absz);
    zd      = signz * sqrt(2.0 / absz);
    cons    = zd / 2.0;
    pibyz   = PI / z;
    startr  += numkern / (double) (2 * numbetween);
    delta   = -1.0 / numbetween;

    r       = startr + rx * delta;

    yy      = r * zd;
    zz      = yy + z * zd;
    xx      = pibyz * r * r;
    c       = cos(xx);
    s       = sin(xx);
    fresnl(yy, &fressy, &frescy);
    fresnl(zz, &fressz, &frescz);
    tmprl = signz * (frescz - frescy);
    tmpim = fressy - fressz;

    *rr     = (tmprl * c - tmpim * s) * cons;
    *ri     = -(tmprl * s + tmpim * c) * cons;
  }
}

/** Create the convolution kernel for one f-∂f plain
 *
 *  This is "copied" from gen_z_response in respocen.c
 *
 * @param response
 * @param maxZ
 * @param fftlen
 * @param frac
 */
__global__ void init_kernels(float* response, int maxZ, int fftlen, float frac)
{
  int cx, cy;                       /// The x and y index of this thread in the array
  int rx = -1;                      /// The x index of the value in the kernel

  // Calculate the 2D index of this thread
  cx = blockDim.x * blockIdx.x + threadIdx.x;// use BLOCKSIZE rather (its constant)
  cy = blockDim.y * blockIdx.y + threadIdx.y;// use BLOCKSIZE rather (its constant)

  float z = -maxZ + cy * ACCEL_DZ;   /// The Fourier Frequency derivative

  if ( z < -maxZ || z > maxZ || cx >= fftlen || cx < 0 )
  {
    // Out of bounds
    return;
  }

  // Calculate the response x position from the plain x position
  int kern_half_width = z_resp_halfwidth((double) z);
  int hw = ACCEL_NUMBETWEEN * kern_half_width;
  int numkern = 2 * hw;           /// The number of complex points that the kernel row will contain
  if (cx < hw)
    rx = cx + hw;
  else if (cx >= fftlen - hw)
    rx = cx - (fftlen - hw);

  FOLD // Calculate the response value
  {
    float rr = 0;               /// The real part of the complex response
    float ri = 0;               /// The imaginary part of the complex response

    if (rx != -1)
    {
      float absz = fabs(z);

      if (absz < 1E-4 )    // If z~=0 use the normal Fourier interpolation kernel
      {
        gen_r_response (rx, 0.0, ACCEL_NUMBETWEEN, numkern, &rr, &ri);
      }
      else                 // Calculate the complex response value for Fourier f-dot interpolation.
      {
        gen_z_response (rx, z, absz, ACCEL_NUMBETWEEN, numkern, &rr, &ri);
      }
    }

    response[(cy * fftlen + cx) * 2    ]  = rr;
    response[(cy * fftlen + cx) * 2 + 1]  = ri;
  }
}

/** Create the convolution kernel for an entire stack
 *
 * @param response
 * @param stack
 * @param fftlen
 * @param stride
 * @param maxh
 * @param maxZa
 * @param startR
 * @param zmax
 */
__global__ void init_kernels_stack(float2* response, const int fftlen, const int stride, const int maxh, const int noPlains, iList startR, fList zmax)
{
  int cx, cy;                       /// The x and y index of this thread in the array
  int rx = -1;                      /// The x index of the value in the kernel
  int plain = -1;                   /// The f-∂f plain the thread deals with
  float maxZ;                       /// The Z-Max of the plain this thread deals with

  // Calculate the 2D index of this thread
  cx = blockDim.x * blockIdx.x + threadIdx.x;// use BLOCKSIZE rather (its constant)
  cy = blockDim.y * blockIdx.y + threadIdx.y;// use BLOCKSIZE rather (its constant)

  if ( cy >= maxh || cx >= fftlen || cx < 0 )
  {
    // Out of bounds
    return;
  }

  // Calculate which plain in the stack we are working with
  for ( int i = 0; i < noPlains; i++ )
  {
    if ( cy >= startR.val[i] && cy < startR.val[i + 1] )
    {
      plain = i;
      break;
    }
  }
  maxZ = zmax.val[plain];
  float z = -maxZ + (cy-startR.val[plain]) * ACCEL_DZ; /// The Fourier Frequency derivative

  // Calculate the response x position from the plain x position
  int kern_half_width = z_resp_halfwidth((double) z);
  int hw = ACCEL_NUMBETWEEN * kern_half_width;
  int numkern = 2 * hw;             /// The number of complex points that the kernel row will contain
  if (cx < hw)
    rx = cx + hw;
  else if (cx >= fftlen - hw)
    rx = cx - (fftlen - hw);

  FOLD // Calculate the response value
  {
    float rr = 0;
    float ri = 0;

    if (rx != -1)
    {
      double absz = fabs(z);
      if (absz < 1E-4 )     // If z~=0 use the normal Fourier interpolation kernel
      {
        gen_r_response(rx, 0.0, ACCEL_NUMBETWEEN, numkern, &rr, &ri);
      }
      else                  // Calculate the complex response value for Fourier f-dot interpolation.
      {
        gen_z_response (rx, z, absz, ACCEL_NUMBETWEEN, numkern, &rr, &ri);
      }
    }

    float2 tmp2 = { rr, ri };
    response[cy * fftlen + cx] = tmp2;
    //response[(cy*fftlen+cx)*2]    = rr;
    //response[(cy*fftlen+cx)*2+1]  = ri;
  }
}

//template<uint FLAGS, typename sType, int noStages, typename stpType>
/*
__global__ void print_YINDS(int no)
{
  const int bidx  = threadIdx.y * SS3_X       +   threadIdx.x;
  const int tid   = blockIdx.x  * (SS3_Y*SS3_X) + bidx;

  if ( tid == 0 )
  {
    printf("%p\n", YINDS );

    for(int i = 0 ; i < no; i ++)
    {
      printf("%03i: %-5i  %i \n", i, YINDS[i], sizeof(int)*8 );
    }
  }
}
 */

void printData_cu(cuFFdotBatch* stkLst, const int FLAGS, int harmonic, int nX, int nY, int sX, int sY)
{
  cuFFdot* cPlain       = &stkLst->plains[harmonic];

  printfData<<<1,1,0,0>>>((float*)cPlain->d_iData, nX, nY, cPlain->harmInf->inpStride, sX, sY);
}

/** The fft length needed to properly process a subharmonic
 *
static int calc_fftlen(int numharm, int harmnum, int max_zfull)
{
  int bins_needed, end_effects;
  double harm_fract;

  harm_fract = (double) harmnum/ (double) numharm;
  bins_needed = ACCEL_USELEN* harm_fract+ 2;
  end_effects = 2* ACCEL_NUMBETWEEN* z_resp_halfwidth(calc_required_z(harm_fract, max_zfull), LOWACC);
  //printf("bins_needed = %d  end_effects = %d  FFTlen = %lld\n",
  //       bins_needed, end_effects, next2_to_n_cu(bins_needed + end_effects));
  return next2_to_n_cu(bins_needed+ end_effects);
}
 */

/* The fft length needed to properly process a subharmonic */
static int calc_fftlen3(double harm_fract, int max_zfull, uint accelLen)
{
  int bins_needed, end_effects;

  bins_needed = accelLen * harm_fract + 2;
  end_effects = 2 * ACCEL_NUMBETWEEN * z_resp_halfwidth(calc_required_z(harm_fract, max_zfull), LOWACC);
  return next2_to_n_cu(bins_needed + end_effects);
}

float cuGetMedian(float *data, uint len)
{
  dim3 dimBlock, dimGrid;
  float* dArrayA = NULL;
  cudaError_t result;

  //cudaMalloc ( ( void ** ) &dArrayA, (maxZ*2+1) * fftlen * sizeof ( float )*2 );
  CUDA_SAFE_CALL(cudaMalloc((void ** ) &dArrayA, (len+ 1)* sizeof(float)), "Failed to allocate device memory for.");
  //__cuSafeCall    (cudaMalloc((void ** ) &dArrayA, (len+ 1)* sizeof(float)), __FILE__, __LINE__, "Failed to allocate device memory for." ) ;
  CUDA_SAFE_CALL(cudaMemcpy(dArrayA, data, len* sizeof(float), cudaMemcpyHostToDevice), "Failed to copy data to device");

  if (len< 49152/ sizeof(float))
  {
    //uint blockSz = 5;
    uint blockSz = BS_DIM;
    //blockSz = 5;

    if (len/ 2.0< blockSz)
      dimBlock.x = ceil(len/ 2.0);
    else
      dimBlock.x = blockSz;

    dimGrid.x = 1;

    uint noBatch = ceilf(len/ 2.0/ dimBlock.x);    // Number of comparisons each thread must do

    //printf ( "Calling kernel %i %i %i (%i %i %i)\n", dimGrid.x, dimGrid.y, dimGrid.z, dimBlock.x, dimBlock.y, dimBlock.z );
    median1Block<<<dimGrid, dimBlock>>>(dArrayA, len, &dArrayA[len], noBatch);

    // Run message
    {
      result = cudaGetLastError();  // This determines whether the kernel was launched

      if (result== cudaSuccess)
      {
        //printf ( "Running kernel ..." );
      }
      else
      {
        fprintf(stderr, "ERROR: Error at kernel launch %s\n", cudaGetErrorString(result));
        exit(EXIT_FAILURE);
      }
    }

    {
      result = cudaDeviceSynchronize();  // This will return when the kernel computation is complete, remember asynchronous execution
      // Complete message;

      if (result== cudaSuccess)
      {
        //printf ( " Complete.\n" );
      }
      else
        fprintf(stderr, "\nERROR: Error after kernel launch %s\n", cudaGetErrorString(result));
    }
    float result;
    CUDA_SAFE_CALL(cudaMemcpy(&result, &dArrayA[len], sizeof(float), cudaMemcpyDeviceToHost), "Failed to copy data back from device");

    return result;
  }
  return 0;
}

/** Calculate an optimal accellen given a width
 *
 * @param width the width of the plain usually a power of two
 * @param zmax
 * @return
 * If width is not a power of two it will be rounded up to the nearest power of two
 */
uint optAccellen(float width, int zmax)
{
  float halfwidth       = z_resp_halfwidth(zmax, LOWACC); /// The halfwidth of the maximum zmax, to calculate accel len
  float pow2            = pow(2 , round(log2(width)) );
  uint oAccelLen        = floor(pow2  - 2 - 2 * ACCEL_NUMBETWEEN * halfwidth);

  return oAccelLen;
}

/** Calculate the step size from a width if the width is < 100 it is skate to be the closest power of two
 *
 * @param width
 * @param zmax
 * @return
 */
uint calcAccellen(int width, int zmax)
{
  int accelLen;

  if ( width > 100 )
  {
    accelLen = width;
  }
  else
  {
    accelLen = optAccellen(width*1000.0,zmax) ;
  }
  return accelLen;
}

int initHarmonics(cuFFdotBatch* batch, cuFFdotBatch* master, int numharmstages, int zmax, fftInfo* fftinf, int device, int noBatches, int noSteps, int width, float*  powcut, long long*  numindep, int flags = 0, int outType = CU_FULLCAND, void* outData = NULL)
{
  nvtxRangePush("initHarmonics");

  size_t free, total;             /// GPU memory
  int noInStack[MAX_HARM_NO];
  int noHarms         = (1 << (numharmstages - 1) );
  int prevWidth       = 0;
  int noStacks        = 0;
  noInStack[0]        = 0;
  size_t totSize      = 0;        /// Total size (in bytes) of all the data need by a family (ie one step) excluding FFT temporary
  size_t fffTotSize   = 0;        /// Total size (in bytes) of FFT temporary memory

  FOLD // See if we can use the cuda device
  {
    if ( device >= getGPUCount() )
    {
      fprintf(stderr, "ERROR: There is no CUDA device %i.\n",device);
      return 0;
    }
    int currentDevvice;
    CUDA_SAFE_CALL(cudaSetDevice(device), "ERROR: cudaSetDevice");
    CUDA_SAFE_CALL(cudaGetDevice(&currentDevvice), "Failed to get device using cudaGetDevice");
    if (currentDevvice != device)
    {
      fprintf(stderr, "ERROR: CUDA Device not set.\n");
      return(0);
    }
    else
    {
      cudaDeviceProp deviceProp;
      CUDA_SAFE_CALL( cudaGetDeviceProperties(&deviceProp, device), "Failed to get device properties device using cudaGetDeviceProperties");
      printf("\nInitializing GPU %i (%s)\n",device,deviceProp.name);
    }
  }

  FOLD // First determine how many stacks and how many harmonics in each stack, accellen  .
  {
    // Allocate and zero
    memset(batch, 0, sizeof(cuFFdotBatch));

    if (master != NULL )  // Copy all pointers and sizes from master. All non global pointers must be overwritten.
      memcpy(batch,  master,  sizeof(cuFFdotBatch));

    // Allocate memory
    batch->hInfos  = (cuHarmInfo*) malloc(noHarms * sizeof(cuHarmInfo));
    batch->kernels = (cuKernel*)   malloc(noHarms * sizeof(cuKernel));

    if (master == NULL )
    {
      // Zero memory for kernels and harmonics
      memset(batch->hInfos,  0, noHarms * sizeof(cuHarmInfo));
      memset(batch->kernels, 0, noHarms * sizeof(cuKernel));

      FOLD // Determine accellen and step size  .
      {
        batch->accelLen = calcAccellen(width,zmax);

        if ( batch->accelLen < 100 )
        {
          fprintf(stderr,"ERROR: With a width of %i, the step-size would be %i and this is too small, try with a wider width or lower z-max.\n", width, batch->accelLen);
          return(1);
        }
        else
        {
          float fftLen      = calc_fftlen3(1, zmax, batch->accelLen);
          int   oAccelLen   = optAccellen(fftLen, zmax);
          float ratio       = batch->accelLen/float(oAccelLen);

          printf("• Using max FFT length of %.0f and thus ", fftLen);

          if ( ratio < 0.95 )
          {
            printf(" an non-optimal step-size of %i.\n", batch->accelLen);
            if ( width > 100 )
            {
              int K              = round(fftLen/1000.0);
              fprintf(stderr,"    WARNING: Using manual width\\step-size is not advised rather set width to one of 2 4 8 46 32.\n    For a zmax of %i using %iK FFTs the optimal step-size is %i.\n", zmax, K, oAccelLen);
            }
          }
          else
          {
            printf(" an optimal step-size of %i.\n", batch->accelLen);
          }
        }
      }

      // Set some harmonic related values
      for (int i = noHarms; i > 0; i--)
      {
        int idx = noHarms-i;
        batch->hInfos[idx].harmFrac    = (i) / (double)noHarms;
        batch->hInfos[idx].zmax        = calc_required_z(batch->hInfos[idx].harmFrac, zmax);
        batch->hInfos[idx].height      = (batch->hInfos[idx].zmax / ACCEL_DZ) * 2 + 1;
        batch->hInfos[idx].halfWidth   = z_resp_halfwidth(batch->hInfos[idx].zmax, LOWACC);
        batch->hInfos[idx].width       = calc_fftlen3(batch->hInfos[idx].harmFrac, batch->hInfos[0].zmax, batch->accelLen);
        batch->hInfos[idx].stackNo     = noStacks;
        //batch->hInfos[idx].numrs       = ceil(batch->accelLen*batch->hInfos[idx].harmFrac);

        if (prevWidth!= batch->hInfos[idx].width)
        {
          noStacks++;
          noInStack[noStacks - 1]       = 0;
          prevWidth                     = batch->hInfos[idx].width;
        }

        noInStack[noStacks - 1]++;
      }

      batch->noHarms                   = noHarms;
      batch->noHarmStages              = numharmstages;
      batch->noStacks                  = noStacks;
    }
    else
    {
      // Zero memory for kernels and harmonics
      memcpy(batch->hInfos,  master->hInfos,  noHarms * sizeof(cuHarmInfo));
      memcpy(batch->kernels, master->kernels, noHarms * sizeof(cuKernel));
    }

    // Set some parameters
    batch->device  = device;
    cuCtxGetCurrent ( &batch->pctx );
  }

  FOLD // Allocate all the memory for the stack data structures  .
  {
    long long neede = batch->noStacks * sizeof(cuFfdotStack) + noHarms * sizeof(cuHarmInfo) + noHarms * sizeof(cuKernel);

    if ( neede > getFreeRamCU() )
    {
      fprintf(stderr, "ERROR: Not enough host memory for search.\n");
    }
    else
    {
      //Set up stacks
      batch->stacks = (cuFfdotStack*) malloc(batch->noStacks* sizeof(cuFfdotStack));

      if (master == NULL )
        memset(batch->stacks, 0, batch->noStacks * sizeof(cuFfdotStack));
      else
        memcpy(batch->stacks, master->stacks, batch->noStacks * sizeof(cuFfdotStack));
    }
  }

  // Set up the basic details of all the harmonics including base flags
  // Calculate the stride of all the stacks (by allocating temporary memory)
  FOLD
  {
    if ( master == NULL )
    {
      FOLD // Set up the basic details of all the harmonics  .
      {
        // Calculate the stage order of the harmonics
        int harmtosum;
        int i = 0;
        for (int stage = 0; stage < numharmstages; stage++)
        {
          harmtosum = 1 << stage;
          for (int harm = 1; harm <= harmtosum; harm += 2, i++)
          {
            float harmFrac                  = 1-harm/ float(harmtosum);
            int idx                         = round(harmFrac*noHarms);
            batch->hInfos[idx].stageOrder  = i;
            batch->pIdx[i]                 = idx;
          }
        }

        batch->flag = flags;

        FOLD // How to handle input and output
        {
          // NOTE:  Generally CU_INPT_SINGLE_C and CU_OUTP_SINGLE are the best options and SINGLE cases generally use less memory as well

          if ( !( batch->flag & CU_INPT_ALL ) )
            batch->flag    |= CU_INPT_SINGLE_C;    // Prepare input data using CPU - Generally bets option, as CPU is "idle"

          if ( !( flags & CU_OUTP_ALL) )
            batch->flag    |= CU_OUTP_SINGLE;      // Only get candidates from the current plain - This seams to be best in most cases
        }

        // Multi-step data layout method  .
        if ( !(batch->flag & FLAG_STP_ALL ) )
        {
          batch->flag |= FLAG_STP_ROW ;          //  FLAG_STP_ROW   or    FLAG_STP_PLN
        }

        FOLD // Convolution flags  .
        {
          //stkLst->flag |= FLAG_CNV_TEX;         // Use texture memory to access the kernel for convolution - May give advantage on pre-Fermi generation which we don't really care about
          batch->flag |= FLAG_CNV_1KER;          // Create a minimal kernel (exploit overlap in stacks)  This should always be the case
          if ( !(batch->flag & FLAG_CNV_ALL ) )
          {
            batch->flag |= FLAG_CNV_STK;         //  FLAG_CNV_PLN   or   FLAG_CNV_STK   or   FLAG_CNV_FAM
          }
        }


        batch->cndType = outType;
      }

      FOLD // Calculate the stride of all the stacks (by allocating temporary memory)  .
      {
        int prev               = 0;
        batch->plnDataSize     = 0;
        batch->pwrDataSize     = 0;
        batch->inpDataSize     = 0;
        batch->kerDataSize     = 0;

        for (int i = 0; i< batch->noStacks; i++)           // Loop through Stacks  .
        {
          cuFfdotStack* cStack  = &batch->stacks[i];
          cStack->height        = 0;
          cStack->noInStack     = noInStack[i];
          cStack->startIdx      = prev;
          cStack->harmInf       = &batch->hInfos[cStack->startIdx];
          cStack->kernels       = &batch->kernels[cStack->startIdx];
          cStack->width         = cStack->harmInf->width;

          for (int j = 0; j< cStack->noInStack; j++)
          {
            cStack->startZ[j]   =  cStack->height;
            cStack->height     += cStack->harmInf[j].height;
            cStack->zUp[j]      =  (cStack->harmInf[0].height - cStack->harmInf[j].height) / 2.0 ;
          }

          for (int j = 0; j< cStack->noInStack; j++)
          {
            cStack->zDn[j]      = ( cStack->harmInf[0].height ) - cStack->zUp[cStack->noInStack - 1 - j ];
          }


          FOLD // Allocate temporary device memory to asses input stride  .
          {
            CUDA_SAFE_CALL(cudaMallocPitch(&cStack->d_kerData, &cStack->inpStride, cStack->width * sizeof(cufftComplex), cStack->harmInf[0].height), "Failed to allocate device memory for kernel stack.");
            CUDA_SAFE_CALL(cudaGetLastError(), "Allocating GPU memory to asses kernel stride.");

            batch->inpDataSize     += cStack->inpStride * cStack->noInStack;          // At this point stride is still in bytes

            if ( batch->flag & FLAG_CNV_1KER )
              batch->kerDataSize   += cStack->inpStride * cStack->harmInf[0].height;  // At this point stride is still in bytes
            else
              batch->kerDataSize   += cStack->inpStride * cStack->height;             // At this point stride is still in bytes

            CUDA_SAFE_CALL(cudaFree(cStack->d_kerData), "Failed to free CUDA memory.");
            CUDA_SAFE_CALL(cudaGetLastError(), "Freeing GPU memory.");
          }

          FOLD // Allocate temporary device memory to asses plain data stride  .
          {
            batch->plnDataSize     += cStack->inpStride * cStack->height;            // At this point stride is still in bytes

            if ( batch->flag & FLAG_CUFFTCB_OUT )
            {
              CUDA_SAFE_CALL(cudaMallocPitch(&cStack->d_plainPowers, &cStack->pwrStride, cStack->width * sizeof(float), cStack->harmInf[0].height), "Failed to allocate device memory for kernel stack.");
              CUDA_SAFE_CALL(cudaGetLastError(), "Allocating GPU memory to asses plain stride.");

              CUDA_SAFE_CALL(cudaFree(cStack->d_plainPowers), "Failed to free CUDA memory.");
              CUDA_SAFE_CALL(cudaGetLastError(), "Freeing GPU memory.");

              batch->pwrDataSize   += cStack->pwrStride * cStack->height;            // At this point stride is still in bytes
              cStack->pwrStride     /= sizeof(float);
            }
            cStack->inpStride       /= sizeof(cufftComplex);                          // Set stride to number of complex numbers rather that bytes

          }
          prev                      += cStack->noInStack;
        }
      }
    }
    else
    {
      // Set up the pointers of each stack
      for (int i = 0; i< batch->noStacks; i++)
      {
        cuFfdotStack* cStack              = &batch->stacks[i];
        cStack->kernels                   = &batch->kernels[cStack->startIdx];
        cStack->harmInf                   = &batch->hInfos[cStack->startIdx];
      }
    }
  }

  FOLD // Allocate device memory for all the kernels data  .
  {
    CUDA_SAFE_CALL(cudaMemGetInfo ( &free, &total ), "Getting Device memory information");

    if ( batch->kerDataSize > free )
    {
      fprintf(stderr, "ERROR: Not enough device memory for GPU convolution kernels. There is only %.2f MB free and you need %.2f MB \n", free / 1048576.0, batch->kerDataSize / 1048576.0 );
      return (0);
    }
    else
    {
      batch->d_kerData = NULL;

      CUDA_SAFE_CALL(cudaMalloc((void **)&batch->d_kerData, batch->kerDataSize), "Failed to allocate device memory for kernel stack.");
      CUDA_SAFE_CALL(cudaGetLastError(), "CUDA Error allocation of device memory for kernel?.\n");
    }
  }

  FOLD // Set the sizes values of the harmonics and kernels and pointers to kernel data  .
  {
    size_t kerSiz = 0;

    for (int i = 0; i< batch->noStacks; i++)
    {
      cuFfdotStack* cStack              = &batch->stacks[i];
      cStack->d_kerData                 = &batch->d_kerData[kerSiz];

      // Set the stride
      for (int j = 0; j< cStack->noInStack; j++)
      {
        cStack->harmInf[j].inpStride    = cStack->inpStride;
        if ( batch->flag & FLAG_CNV_1KER )
        {
          // Point the plain kernel data to the correct position in the "main" kernel
          int iDiff                     = cStack->harmInf[0].height - cStack->harmInf[j].height ;
          float fDiff                   = iDiff / 2.0;
          cStack->kernels[j].d_kerData  = &cStack->d_kerData[cStack->inpStride*(int)fDiff];
        }
        else
          cStack->kernels[j].d_kerData  = &cStack->d_kerData[cStack->startZ[j]*cStack->inpStride];

        cStack->kernels[j].harmInf      = &cStack->harmInf[j];
      }

      if ( batch->flag & FLAG_CNV_1KER )
        kerSiz                          += cStack->inpStride * cStack->harmInf->height;
      else
        kerSiz                          += cStack->inpStride * cStack->height;
    }
  }

  FOLD // Initialise the convolution kernels  .
  {
    if (master == NULL )  // Create the kernels  .
    {
      // Run message
      CUDA_SAFE_CALL(cudaGetLastError(), "Error before creating GPU kernels");

      printf("• Generating GPU convolution kernels\n");

      int hh = 1;
      for (int i = 0; i< batch->noStacks; i++)
      {

        dim3 dimBlock, dimGrid;
        cuFfdotStack* cStack = &batch->stacks[i];

        printf("    Stack %i has %02i f-∂f plain(s) with Width: %5li,  Stride %5li,  Total Height: %6li,   Memory size: %7.1f MB \n", i, cStack->noInStack, cStack->width, cStack->inpStride, cStack->height, cStack->height*cStack->inpStride*sizeof(fcomplex)/1024.0/1024.0);

        dimBlock.x          = BLOCKSIZE;  // in my experience 16 is almost always best (half warp)
        dimBlock.y          = BLOCKSIZE;  // in my experience 16 is almost always best (half warp)

        // call the CUDA kernels
        if ( batch->flag & FLAG_CNV_1KER )
        {
          // Only need one kernel per stack

          FOLD // call the CUDA kernels
          {
            // Set up grid
            dimGrid.x = ceil(  cStack->width  / ( float ) dimBlock.x );
            dimGrid.y = ceil ( cStack->harmInf->height / ( float ) dimBlock.y );

            // Call kernel
            init_kernels<<<dimGrid, dimBlock>>>((float*)cStack->d_kerData, cStack->harmInf->zmax, cStack->width, cStack->harmInf->harmFrac);

            // Run message
            CUDA_SAFE_CALL(cudaGetLastError(), "Error at kernel launch");
          }
        }
        else
        {
          //cuStackHarms cuStack;             // Data structure used to create the convolution kernels
          //cuStack.noInStack   = cStack->noInStack;
          //cuStack.width       = cStack->width;
          //cuStack.stride      = cStack->inpStride;
          //cuStack.height      = cStack->height;

          iList startR;
          fList zmax;
          for (int j = 0; j< cStack->noInStack; j++)
          {
            startR.val[j]     = cStack->startZ[j];
            zmax.val[j]       = cStack->harmInf[j].zmax;
            //cuStack.start[j]  = cStack->startZ[j];
            //cuStack.zmax[j]   = cStack->harmInf[j].zmax;
          }
          startR.val[cStack->noInStack] = cStack->height;

          FOLD // call the CUDA kernels
          {
            // Set up grid
            dimGrid.x = ceil(  cStack->width  / ( float ) dimBlock.x );
            dimGrid.y = ceil ( cStack->height / ( float ) dimBlock.y );

            // Call kernel
            init_kernels_stack<<<dimGrid, dimBlock>>>((float2*) cStack->d_kerData, cStack->width, cStack->inpStride, cStack->height, cStack->noInStack , startR, zmax);

            // Run message
            CUDA_SAFE_CALL(cudaGetLastError(), "Error at kernel launch");
          }
        }

        for (int j = 0; j< cStack->noInStack; j++)
        {
          printf("     Harmonic %2i  Fraction: %5.3f   Z-Max: %4i   Half Width: %4i  ", hh, cStack->harmInf[j].harmFrac, cStack->harmInf[j].zmax, cStack->harmInf[j].halfWidth );
          if ( batch->flag & FLAG_CNV_1KER )
            if ( j == 0 )
              printf("Convolution kernel created: %7.1f MB \n", cStack->harmInf[j].height*cStack->inpStride*sizeof(fcomplex)/1024.0/1024.0);
            else
              printf("\n");
          else
            printf("Convolution kernel created: %7.1f MB \n", cStack->harmInf[j].height*cStack->inpStride*sizeof(fcomplex)/1024.0/1024.0);
          hh++;

        }
      }

      if ( DBG_KER01 )  // Print debug info  .
      {
        for (int i = 0; i< batch->noHarms; i++)
        {
          printf("\nKernel pre FFT %i\n", i);
          //printfData<<<1,1,0,0>>>((float*)stkLst->kernels[i].d_kerData,10,5,stkLst->hInfos[i].stride*2);
          printData_cu(batch, batch->flag, i);
        }
      }

      FOLD // FFT the kernels  .
      {
        printf("   FFT'ing the kernels ");
        cufftHandle plnPlan;
        for (int i = 0; i < batch->noStacks; i++)
        {
          cuFfdotStack* cStack = &batch->stacks[i];

          FOLD // Create the plan
          {
            size_t fftSize        = 0;

            int n[]             = {cStack->width};
            int inembed[]       = {cStack->inpStride* sizeof(fcomplexcu)};
            int istride         = 1;
            int idist           = cStack->inpStride;
            int onembed[]       = {cStack->inpStride* sizeof(fcomplexcu)};
            int ostride         = 1;
            int odist           = cStack->inpStride;
            int height;

            if ( batch->flag & FLAG_CNV_1KER )
              height = cStack->harmInf->height;
            else
              height = cStack->height;

            cufftCreate(&plnPlan);

            CUFFT_SAFE_CALL(cufftMakePlanMany(plnPlan,  1, n, inembed, istride, idist, onembed, ostride, odist, CUFFT_C2C, height,    &fftSize), "Creating plan for complex data of stack.");
            fffTotSize += fftSize;

            CUDA_SAFE_CALL(cudaGetLastError(), "Creating FFT plans for the stacks.");
          }

          // Call the plan
          CUFFT_SAFE_CALL(cufftExecC2C(plnPlan, (cufftComplex *) cStack->d_kerData, (cufftComplex *) cStack->d_kerData, CUFFT_FORWARD),"FFT'ing the kernel data");
          printf(".");
          std::cout.flush();

          // Destroy the plan
          CUFFT_SAFE_CALL(cufftDestroy(plnPlan), "Destroying plan for complex data of stack.");
        }
        CUDA_SAFE_CALL(cudaGetLastError(), "FFT'ing the convolution kernels.");
        printf("\n");
      }

      printf("  Done generating GPU convolution kernels.\n");

      if ( DBG_KER02 )  // Print debug info
      {
        for (int i = 0; i< batch->noHarms; i++)
        {
          printf("\nKernel post FFT %i\n", i);
          //printfData<<<1,1,0,0>>>((float*)stkLst->kernels[stkLst->pIdx[i]].d_kerData,10,5,stkLst->hInfos[stkLst->pIdx[i]].stride*2);
          printData_cu(batch, batch->flag, batch->pIdx[i]);
          CUDA_SAFE_CALL(cudaStreamSynchronize(0),"Printing debug info");
        }
      }

      if ( DBG_PRNTKER02 ) // Draw the kernel
      {
        /*
        char fname[1024];
        for (int i = 0; i< batch->noHarms; i++)
        {
          sprintf(fname, "./ker_%02i_GPU.png",i);
          drawPlainCmplx(batch->kernels[batch->pIdx[i]].d_kerData, fname, batch->hInfos[batch->pIdx[i]].inpStride, batch->hInfos[batch->pIdx[i]].height );
          CUDA_SAFE_CALL(cudaStreamSynchronize(0),"Printing debug info");
        }
        */
      }
    }
    else                  // Copy kernels from master device
    {
      printf("• Copying convolution kernels from device %i.\n", master->device);
      CUDA_SAFE_CALL(cudaMemcpyPeer(batch->d_kerData, batch->device, master->d_kerData, master->device, master->kerDataSize ), "Copying convolution kernels between devices.");
    }
  }

  FOLD // Decide how to handle input and output and allocate required memory  .
  {
    printf("• Examining device %2i:\n", batch->device);

    ulong freeRam;          /// The amount if free host memory
    int retSZ   = 0;        /// The size in byte of the returned data
    int candSZ  = 0;        /// The size in byte of the candidates
    int noRets;             /// The number of candidates return per family (one step)
    ulong deviceC  = 0;     /// The size in bytes of device memory used for candidates
    ulong hostC    = 0;     /// The size in bytes of device memory used for candidates

    if ( master == NULL )   // Calculate the search size in bins  .
    {
      int minR              = floor ( fftinf->rlo / (double)noHarms - batch->hInfos[0].halfWidth );
      int maxR              = ceil  ( fftinf->rhi  + batch->hInfos[0].halfWidth );

      searchScale* SrchSz   = new searchScale;
      batch->SrchSz         = SrchSz;

      SrchSz->searchRLow    = fftinf->rlo / (double)noHarms;
      SrchSz->searchRHigh   = fftinf->rhi;
      SrchSz->rLow          = minR;
      SrchSz->rHigh         = maxR;
      SrchSz->noInpR        = maxR - minR  ;  /// The number of input data points

      if ( batch->flag  & FLAG_STORE_EXP )
      {
        SrchSz->noOutpR     = ceil( (SrchSz->searchRHigh - SrchSz->searchRLow)/ACCEL_DR );
      }
      else
      {
        SrchSz->noOutpR     = ceil(SrchSz->searchRHigh - SrchSz->searchRLow);
      }

      if ( (batch->flag & FLAG_STORE_ALL) && !( batch->flag  & FLAG_RETURN_ALL) )
      {
        printf("   Storing all results implies returning all results so adding FLAG_RETURN_ALL to flags!\n");
        batch->flag  |= FLAG_RETURN_ALL;
      }
    }

    FOLD // Calculate candidate type  .
    {
      batch->retType = batch->cndType;



      if      (batch->cndType == CU_NONE   )
      {
        fprintf(stderr,"Warning: No output type specified in %s setting to full candidate info.\n",__FUNCTION__);
        batch->cndType = CU_FULLCAND;
      }

      if      (batch->cndType == CU_CMPLXF   )
      {
        candSZ = sizeof(fcomplexcu);
      }
      else if (batch->cndType == CU_INT      )
      {
        candSZ = sizeof(int);
      }
      else if (batch->cndType == CU_FLOAT    )
      {
        candSZ = sizeof(float);
      }
      else if (batch->cndType == CU_POWERZ   )
      {
        candSZ = sizeof(accelcand2);
      }
      else if (batch->cndType == CU_SMALCAND )
      {
        candSZ = sizeof(accelcandBasic);
      }
      else if (batch->cndType == CU_FULLCAND || (batch->cndType == CU_GSList) )
      {
        candSZ = sizeof(cand);
        batch->retType = CU_SMALCAND;
      }
      else
      {
        fprintf(stderr,"ERROR: No output type specified in %s setting to full candidate info.\n",__FUNCTION__);
        batch->cndType = CU_FULLCAND;
        candSZ = sizeof(cand);
        batch->retType = CU_SMALCAND;
      }
    }

    FOLD // Calculate candidate return type and size  .
    {
      if      (batch->retType == CU_CMPLXF   )
      {
        retSZ = sizeof(fcomplexcu);
      }
      else if (batch->retType == CU_INT      )
      {
        retSZ = sizeof(int);
      }
      else if (batch->retType == CU_FLOAT    )
      {
        retSZ = sizeof(float);
      }
      else if (batch->retType == CU_POWERZ   )
      {
        retSZ = sizeof(accelcand2);
      }
      else if (batch->retType == CU_SMALCAND )
      {
        retSZ = sizeof(accelcandBasic);
      }
      else if (batch->retType == CU_FULLCAND )
      {
        retSZ = sizeof(cand);
      }
      else
      {
        fprintf(stderr,"ERROR: No output type specified in %s\n",__FUNCTION__);
      }

      noRets                = batch->hInfos[0].width;  // NOTE: This could be accellen rather than width, but to allow greater flexibility keep it at width

      if ( batch->flag & FLAG_RETURN_ALL )
        noRets *= numharmstages;

      batch->retDataSize   = noRets*retSZ;
    }

    FOLD // calculate batch size and number of steps and batches on this device  .
    {
      CUDA_SAFE_CALL(cudaMemGetInfo ( &free, &total ), "Getting Device memory information");
      freeRam = getFreeRamCU();
      printf("   There is a total of %.2f GiB of device memory of which there is %.2f GiB free and %.2f GiB free host memory.\n",total / 1073741824.0, (free )  / 1073741824.0, freeRam / 1073741824.0 );

      totSize              += batch->plnDataSize + batch->pwrDataSize + batch->inpDataSize + batch->retDataSize;
      fffTotSize            = batch->plnDataSize + batch->inpDataSize;

      float noKers2 = ( free ) / (double) ( fffTotSize + totSize * noBatches ) ;  // (fffTotSize * noKers2) for the CUFFT memory for FFT'ing the plain(s) and (totSize * noThreads * noKers2) for each thread(s) plan(s)

      printf("     Requested %i batches on this device.\n", noBatches);
      if ( noKers2 > 1 )
      {
        if ( noSteps > floor(noKers2) )
        {
          printf("      Requested %i steps per batch, but with %i batches we can only do %.2f steps per batch. \n",noSteps, noBatches, noKers2 );
          noSteps = floor(noKers2);
        }

        if ( floor(noKers2) > noSteps + 1 && (noSteps < MAX_STEPS) )
          printf("       Note: requested %i steps per batch, you could do up to %.2f steps per batch. \n",noSteps, noKers2 );

        batch->noSteps = noSteps;

        if ( batch->noSteps > MAX_STEPS )
        {
          batch->noSteps = MAX_STEPS;
          printf("      Trying to use more steps that the maximum number (%li) this code is compiled with.\n", batch->noSteps );
        }
      }
      else
      {
        // TODO: check if we can do more than one step or set number of batches??
        printf("      There is not be enough memory to do %i batches, throttling to 1 step per batch.\n", noBatches);
        batch->noSteps = 1;                  // Default we have to do at least one step at a time
      }

      if ( noBatches <= 0 || noSteps <= 0 )
      {
        fprintf(stderr, "ERROR: Insufficient memory to make make any plains on this device.\n");
        CUDA_SAFE_CALL(cudaFree(batch->d_kerData), "Failed to free device memory for kernel stack.");
        return 0;
      }
      printf("     Processing %i steps with each of the %i batch(s)\n", noSteps, noBatches );
      //batch->mxSteps = batch->noSteps;

      printf("    Kernels      use: %5.2f GiB of device memory.\n", (batch->kerDataSize) / 1073741824.0 );
      printf("    CUFFT        use: %5.2f GiB of device memory.\n", (fffTotSize*batch->noSteps) / 1073741824.0 );
      printf("    Each batch  uses: %5.2f GiB of device memory.\n", (totSize*batch->noSteps) / 1073741824.0 );
      printf("               Using: %5.2f GiB of %.2f [%.2f%%] device memory for plains.\n", (batch->kerDataSize + ( fffTotSize + totSize * noBatches )*batch->noSteps ) / 1073741824.0, total / 1073741824.0, (batch->kerDataSize + ( fffTotSize + totSize * noBatches )*batch->noSteps ) / (float)total * 100.0f );
    }

    float fullISize     = batch->SrchSz->noInpR  * sizeof(fcomplexcu);   /// The full size of relevant input data
    float fullRSize     = batch->SrchSz->noOutpR * retSZ;                /// The full size of all data returned
    float fullCSize     = batch->SrchSz->noOutpR * candSZ;               /// The full size of all candidate data
    float fullSem       = batch->SrchSz->noOutpR * sizeof(uint);         /// size of semaphores

    if ( batch->flag  & FLAG_RETURN_ALL )
      fullRSize *= numharmstages; // Store  candidates for all stages

    if ( batch->flag  & FLAG_STORE_ALL )
      fullCSize *= numharmstages; // Store  candidates for all stages

    FOLD // Do sanity checks for input and output and adjust "down" if necessary
    {
      float remainigGPU   = free - fffTotSize*batch->noSteps - totSize*batch->noSteps*noBatches ;
      float remainingRAM  = freeRam;

      if ( batch->flag & CU_INPT_DEVICE 	)
      {
        if ( fullISize > remainigGPU*0.98 )
        {
          fprintf(stderr, "WARNING: Requested to store all input data on device but there is insufficient space so changing to page locked memory instead.\n");
          batch->flag ^= CU_INPT_DEVICE;
          batch->flag |= CU_INPT_HOST;
        }
        else
        {
          // We can get all points on the device
          remainigGPU -= fullISize ;
        }
      }

      if ( batch->flag & CU_INPT_HOST 	  )
      {
        if (fullISize > remainingRAM*0.98 )
        {
          fprintf(stderr, "WARNING: Requested to store all input data in page locked host memory but there is insufficient space, so changing to working on single stack at a time.\n");
          batch->flag ^= CU_INPT_HOST;
          batch->flag |= CU_INPT_SINGLE_C;
        }
        else
        {
          // We can get all points in ram
          remainingRAM -= fullISize ;
        }
      }

      if ( batch->flag & CU_OUTP_DEVICE   )
      {
        if ( fullCSize > remainigGPU *0.98 )
        {
          if(master == NULL)
          {
            fprintf(stderr, "WARNING: Requested to store all candidates on device but there is insufficient space so changing to page locked memory instead.\n");
            batch->flag ^= CU_OUTP_DEVICE;
            batch->flag |= CU_OUTP_HOST;
          }
          else
          {
            fprintf(stderr, "ERROR: GPU %i has insufficient free memory to store all candidates on device.\n");
            return 0;
          }
        }
        else
        {
          remainigGPU -= fullRSize ;
        }
      }

      if ( ( batch->flag & CU_OUTP_HOST 	) || ( batch->flag & CU_OUTP_DEVICE ) )
      {
        if(master == NULL)
        {
          if ( fullCSize > remainingRAM *0.98 )
          {
            fprintf(stderr, "WARNING: Requested to store all candidates in page locked host memory but there is insufficient space, so changing to working on single stack at a time.\n");
            if ( batch->flag & CU_OUTP_DEVICE  )
              fprintf(stderr, "         This is strange you appear to have enough GPU memory for to store all candidates but not enough host RAM.\n");
            batch->flag ^= CU_OUTP_HOST;
            batch->flag ^= CU_OUTP_DEVICE;
            batch->flag |= CU_OUTP_SINGLE;
          }
          else
          {
            remainingRAM -= fullRSize ;
          }
        }
      }
    }

    FOLD // ALLOCATE device specific memory  .
    {
      if      ( batch->flag & CU_INPT_DEVICE )
      {
        // Create and copy raw fft data to the device
        CUDA_SAFE_CALL(cudaMalloc((void** )&batch->d_iData, fullISize), "Failed to allocate device memory for input raw FFT data.");
        CUDA_SAFE_CALL(cudaMemcpy(batch->d_iData, &fftinf->fft[batch->SrchSz->rLow], fullISize, cudaMemcpyHostToDevice), "Failed to copy raw FFT data to device.");
        deviceC += fullISize;
      }
      else if ( batch->flag & CU_INPT_HOST   )
      {
        if (master == NULL )
        {
          // Create page locked host memory and copy raw fft data - for the entire input data
          CUDA_SAFE_CALL(cudaMallocHost((void**) &batch->h_iData, fullISize), "Failed to create page-locked host memory for entire input data." );
          deviceC+=fullISize;

          int start = 0;   /// Number of bins to zero pad the beginning
          if ( batch->SrchSz->rLow < 0 ) // Zero pad if necessary
          {
            start = -batch->SrchSz->rLow;
            memset(batch->h_iData, 0, start*sizeof(fcomplex) );
          }

          // Copy input data to pagelocked memory
          memcpy(&batch->h_iData[start], &fftinf->fft[batch->SrchSz->rLow+start], (fullISize-start)*sizeof(fcomplex));
          hostC += fullISize;
        }
      }
      else if ( batch->flag & CU_INPT_SINGLE )
      {
        // Nothing, each batch has its own input data already
      }
      else
      {
        fprintf(stderr, "ERROR: Undecided how to handle input data!\n");
        return 0;
      }

      if      ( batch->flag & CU_OUTP_DEVICE )
      {
        // Create a candidate list
        CUDA_SAFE_CALL(cudaMalloc((void** )&batch->d_retData, fullRSize), "Failed to allocate device memory for candidate list stack.");
        CUDA_SAFE_CALL(cudaMemset((void*)batch->d_retData, 0, fullRSize ), "Failed to initialise  candidate list.");
        deviceC += fullRSize;

        // Create a semaphore list
        CUDA_SAFE_CALL(cudaMalloc((void** )&batch->d_candSem, fullSem ), "Failed to allocate device memory for candidate semaphore list.");
        CUDA_SAFE_CALL(cudaMemset((void*)batch->d_candSem, UINT_MAX, fullSem ), "Failed to initialise  semaphore list.");
        deviceC += fullSem;
      }
      else if ( ( batch->flag & CU_OUTP_HOST ) || ( batch->flag & CU_OUTP_DEVICE ) )
      {
        if ( master == NULL )
        {
          CUDA_SAFE_CALL(cudaMallocHost((void**) &batch->h_retData, fullRSize), "Failed to create page-locked host memory for entire candidate list." );
          memset(batch->h_retData, 0, fullRSize);
          hostC += fullRSize;
        }
      }
      else if ( batch->flag & CU_OUTP_SINGLE )
      {
        // Nothing, each batch has its own return data already
      }
      else
      {
        fprintf(stderr, "ERROR: Undecided how to handle input data!");
        return 0;
      }
    }

    FOLD // Allocate global (device independent) host memory
    {
      // One set of global set of "candidates" for all devices
      if ( master == NULL )
      {
        if( batch->flag | CU_CAND_ARR )
        {
          if ( outData == NULL )
          {
            freeRam  = getFreeRamCU();
            if ( fullCSize < freeRam*0.98 )
            {
              // Same host candidates for all devices
              // This can use a lot of memory for long searches!
              batch->h_candidates = malloc( fullCSize );
              memset(batch->h_candidates, 0, fullCSize );
              hostC += fullCSize;
            }
            else
            {
              fprintf(stderr, "ERROR: Not enough host memory for candidate list array. Need %.2fGiB there is %.2fGiB.\n", fullCSize / 1073741824.0, freeRam / 1073741824.0 );
              fprintf(stderr, "       Try set -fhi to a lower value. ie: numharm*1000. ( or buy more RAM, or close Chrome ;)\n");
              fprintf(stderr, "       Will continue trying to use a dynamic list.\n");

              batch->flag ^= CU_CAND_ARR;
              batch->flag |= CU_CAND_LST;
            }
          }
          else
          {
            // This memory has already been allocated
            batch->h_candidates = outData;
            memset(batch->h_candidates, 0, fullCSize );
          }
        }
      }
    }

    if ( deviceC + hostC )
    {
      printf("    Input and candidates use and additional:\n");
      if ( deviceC )
        printf("                      %5.2f GiB of device memory\n", deviceC / 1073741824.0 );
      if ( hostC )
        printf("                      %5.2f GiB of host   memory\n", hostC / 1073741824.0 );
    }

    CUDA_SAFE_CALL(cudaGetLastError(), "Failed to create memory for candidate list or input data.");

    printf("  Done\n");
  }

  FOLD // Stack specific events  .
  {
    char tmpStr[1024];

    for (int i = 0; i< batch->noStacks; i++)
    {
      cuFfdotStack* cStack = &batch->stacks[i];
      CUDA_SAFE_CALL(cudaStreamCreate(&cStack->fftIStream),"Creating CUDA stream for fft's");
      sprintf(tmpStr,"%i FFT Input %i Stack", device, i);
      nvtxNameCudaStreamA(cStack->fftIStream, tmpStr);
    }

    for (int i = 0; i< batch->noStacks; i++)
    {
      cuFfdotStack* cStack = &batch->stacks[i];
      CUDA_SAFE_CALL(cudaStreamCreate(&cStack->fftPStream),"Creating CUDA stream for fft's");
      sprintf(tmpStr,"%i FFT Plain %i Stack", device, i);
      nvtxNameCudaStreamA(cStack->fftPStream, tmpStr);
    }
  }

  FOLD // Create texture memory from kernels  .
  {
    if ( batch->flag & FLAG_CNV_TEX )
    {
      cudaChannelFormatDesc channelDesc = cudaCreateChannelDesc(32, 32, 0, 0, cudaChannelFormatKindFloat);

      CUDA_SAFE_CALL(cudaGetLastError(), "CUDA Error creating texture from kernel data.");

      for (int i = 0; i< batch->noStacks; i++)           // Loop through Stacks
      {
        cuFfdotStack* cStack = &batch->stacks[i];

        struct cudaTextureDesc texDesc;
        memset(&texDesc, 0, sizeof(texDesc));
        texDesc.addressMode[0]    = cudaAddressModeClamp;
        texDesc.addressMode[1]    = cudaAddressModeClamp;
        texDesc.filterMode        = cudaFilterModePoint;
        texDesc.readMode          = cudaReadModeElementType;
        texDesc.normalizedCoords  = 0;

        cudaResourceDesc resDesc;
        memset(&resDesc, 0, sizeof(resDesc));
        resDesc.resType                   = cudaResourceTypePitch2D;
        resDesc.res.pitch2D.desc          = channelDesc;
        resDesc.res.pitch2D.devPtr        = cStack->d_kerData;
        resDesc.res.pitch2D.width         = cStack->width;
        resDesc.res.pitch2D.pitchInBytes  = cStack->inpStride * sizeof(fcomplex);

        if ( batch->flag & FLAG_CNV_1KER )
          resDesc.res.pitch2D.height      = cStack->harmInf->height;
        else
          resDesc.res.pitch2D.height      = cStack->height;

        CUDA_SAFE_CALL(cudaCreateTextureObject(&cStack->kerDatTex, &resDesc, &texDesc, NULL), "Error Creating texture from kernel data.");

        CUDA_SAFE_CALL(cudaGetLastError(), "CUDA Error creating texture from the stack of kernel data.");

        // Create the actual texture object
        for (int j = 0; j< cStack->noInStack; j++)        // Loop through plains in stack
        {
          cuKernel* cKer = &cStack->kernels[j];

          resDesc.res.pitch2D.devPtr        = cKer->d_kerData;
          resDesc.res.pitch2D.height        = cKer->harmInf->height;
          resDesc.res.pitch2D.width         = cKer->harmInf->width;
          resDesc.res.pitch2D.pitchInBytes  = cStack->inpStride * sizeof(fcomplex);

          CUDA_SAFE_CALL(cudaCreateTextureObject(&cKer->kerDatTex, &resDesc, &texDesc, NULL), "Error Creating texture from kernel data.");
          CUDA_SAFE_CALL(cudaGetLastError(), "CUDA Error creating texture from kernel data.");
        }
      }
    }
  }

  FOLD // Set constant memory values  .
  {
    setConstVals( batch,  numharmstages, powcut, numindep );
    copyCUFFT_LD_CB();
  }

  FOLD // Create CUFFT plans, ( 1 - set per device )  .
  {
    fffTotSize = 0;
    for (int i = 0; i < batch->noStacks; i++)
    {
      cuFfdotStack* cStack  = &batch->stacks[i];
      size_t fftSize        = 0;

      FOLD
      {
        int n[]             = {cStack->width};
        int inembed[]       = {cStack->inpStride* sizeof(fcomplexcu)};
        int istride         = 1;
        int idist           = cStack->inpStride;
        int onembed[]       = {cStack->inpStride* sizeof(fcomplexcu)};
        int ostride         = 1;
        int odist           = cStack->inpStride;

        cufftCreate(&cStack->plnPlan);
        cufftCreate(&cStack->inpPlan);

        CUFFT_SAFE_CALL(cufftMakePlanMany(cStack->plnPlan,  1, n, inembed, istride, idist, onembed, ostride, odist, CUFFT_C2C, cStack->height*batch->noSteps,    &fftSize), "Creating plan for complex data of stack.");
        fffTotSize += fftSize;

        CUFFT_SAFE_CALL(cufftMakePlanMany(cStack->inpPlan,  1, n, inembed, istride, idist, onembed, ostride, odist, CUFFT_C2C, cStack->noInStack*batch->noSteps, &fftSize), "Creating plan for input data of stack.");
        fffTotSize += fftSize;
      }
      CUDA_SAFE_CALL(cudaGetLastError(), "Creating FFT plans for the stacks.");
    }
  }

  printf("Done initialising GPU %i.\n",device);
  nvtxRangePop();

  return noBatches;
}

void freeHarmonics(cuFFdotBatch* kernel, cuFFdotBatch* master)
{
  FOLD // Allocate device memory for all the kernels data  .
  {
    CUDA_SAFE_CALL(cudaFree(kernel->d_kerData), "Failed to allocate device memory for kernel stack.");
    CUDA_SAFE_CALL(cudaGetLastError(), "CUDA Error allocation of device memory for kernel?.\n");
  }

  FOLD // Create texture memory from kernels  .
  {
    if ( kernel->flag & FLAG_CNV_TEX )
    {
      cudaChannelFormatDesc channelDesc = cudaCreateChannelDesc(32, 32, 0, 0, cudaChannelFormatKindFloat);

      CUDA_SAFE_CALL(cudaGetLastError(), "CUDA Error creating texture from kernel data.");

      for (int i = 0; i< kernel->noStacks; i++)           // Loop through Stacks
      {
        cuFfdotStack* cStack = &kernel->stacks[i];

        cudaDestroyTextureObject(cStack->kerDatTex);
        CUDA_SAFE_CALL(cudaGetLastError(), "CUDA Error creating texture from the stack of kernel data.");

        // Create the actual texture object
        for (int j = 0; j< cStack->noInStack; j++)        // Loop through plains in stack
        {
          cuKernel* cKer = &cStack->kernels[j];

          cudaDestroyTextureObject(cKer->kerDatTex);
          CUDA_SAFE_CALL(cudaGetLastError(), "CUDA Error creating texture from kernel data.");
        }
      }
    }
  }

  FOLD // Decide how to handle input and output and allocate required memory  .
  {
    if ( master == kernel )
      free(kernel->SrchSz);

    FOLD // ALLOCATE device specific memory  .
    {
      if      ( kernel->flag & CU_INPT_DEVICE )
      {
        // Create and copy raw fft data to the device
        CUDA_SAFE_CALL(cudaFree(kernel->d_iData), "Failed to allocate device memory for input raw FFT data.");
      }
      else if ( kernel->flag & CU_INPT_HOST   )
      {
        if ( master == kernel )
        {
          // Create page locked host memory and copy raw fft data - for the entire input data
          CUDA_SAFE_CALL(cudaFreeHost(kernel->h_iData), "Failed to create page-locked host memory for entire input data." );
        }
      }

      if      ( kernel->flag & CU_OUTP_DEVICE )
      {
        // Create a candidate list
        CUDA_SAFE_CALL(cudaFree(kernel->d_retData), "Failed to allocate device memory for candidate list stack.");

        // Create a semaphore list
        CUDA_SAFE_CALL(cudaFree(kernel->d_candSem), "Failed to allocate device memory for candidate semaphore list.");
      }
      else if ( ( kernel->flag & CU_OUTP_HOST ) || ( kernel->flag & CU_OUTP_DEVICE ) )
      {
        if ( master == kernel )
        {
          CUDA_SAFE_CALL(cudaFreeHost(kernel->h_retData), "Failed to create page-locked host memory for entire candidate list." );
        }
      }
    }

    FOLD // Allocate global (device independent) host memory
    {
      // One set of global set of "candidates" for all devices
      if ( master == kernel )
      {
        if( kernel->flag | CU_CAND_ARR )
        {
          if ( kernel->h_candidates )
          {
            free(kernel->h_candidates);
          }
        }
      }
    }

    CUDA_SAFE_CALL(cudaGetLastError(), "Failed to create memory for candidate list or input data.");
  }

  FOLD // Create CUFFT plans, ( 1 - set per device )  .
  {
    for (int i = 0; i < kernel->noStacks; i++)
    {
      cuFfdotStack* cStack  = &kernel->stacks[i];
      CUFFT_SAFE_CALL(cufftDestroy(cStack->plnPlan), "Destroying plan for complex data of stack.");
      CUFFT_SAFE_CALL(cufftDestroy(cStack->inpPlan), "Destroying plan for complex data of stack.");
      CUDA_SAFE_CALL(cudaGetLastError(), "Creating FFT plans for the stacks.");
    }
  }

  FOLD // Allocate all the memory for the stack data structures  .
  {
    free(kernel->stacks);
  }
}

void setPlainPointers(cuFFdotBatch* stkLst)
{
  for (int i = 0; i < stkLst->noStacks; i++)
  {
    // Set stack pointers
    cuFfdotStack* cStack  = &stkLst->stacks[i];

    for (int j = 0; j < cStack->noInStack; j++)
    {
      cuFFdot* cPlain           = &cStack->plains[j];

      if ( (stkLst->flag & FLAG_STP_ROW) || (stkLst->flag & FLAG_STP_PLN) )
      {
        cPlain->d_plainData     = &cStack->d_plainData[   cStack->startZ[j] * stkLst->noSteps * cStack->inpStride];
        cPlain->d_plainPowers   = &cStack->d_plainPowers[ cStack->startZ[j] * stkLst->noSteps * cStack->pwrStride];
      }
      else // Note this works for 1 step or FLAG_STP_STK
      {
        cPlain->d_plainData     = &cStack->d_plainData[   cStack->startZ[j] * cStack->inpStride];
        cPlain->d_plainPowers   = &cStack->d_plainPowers[ cStack->startZ[j] * cStack->pwrStride];
      }

      cPlain->d_iData           = &cStack->d_iData[cStack->inpStride*j*stkLst->noSteps];
      cPlain->harmInf           = &cStack->harmInf[j];
      cPlain->kernel            = &cStack->kernels[j];
    }
  }
}

void setStkPointers(cuFFdotBatch* stkLst)
{
  size_t cmplStart  = 0;
  size_t pwrStart   = 0;
  size_t idSiz      = 0;            /// The size in bytes of input data for one stack
  int harm          = 0;

  for (int i = 0; i < stkLst->noStacks; i++) // Set stack pointers
  {
    cuFfdotStack* cStack  = &stkLst->stacks[i];

    cStack->d_iData       = &stkLst->d_iData[idSiz];
    cStack->h_iData       = &stkLst->h_iData[idSiz];
    cStack->plains        = &stkLst->plains[harm];
    cStack->kernels       = &stkLst->kernels[harm];
    cStack->d_plainData   = &stkLst->d_plainData[cmplStart];
    cStack->d_plainPowers = &stkLst->d_plainPowers[pwrStart];

    harm                 += cStack->noInStack;
    idSiz                += stkLst->noSteps * cStack->inpStride * cStack->noInStack;
    cmplStart            += cStack->height  * cStack->inpStride * stkLst->noSteps ;
    pwrStart             += cStack->height  * cStack->pwrStride * stkLst->noSteps ;
  }

  setPlainPointers(stkLst);
}

int initBatch(cuFFdotBatch* stkLst, cuFFdotBatch* kernel, int no, int of)
{
  char tmpStr[1024];
  size_t free, total;

  FOLD // See if we can use the cuda device  .
  {
    int currentDevvice;
    CUDA_SAFE_CALL(cudaSetDevice(kernel->device), "ERROR: cudaSetDevice");
    CUDA_SAFE_CALL(cudaGetDevice(&currentDevvice), "Failed to get device using cudaGetDevice");
    if (currentDevvice != kernel->device)
    {
      fprintf(stderr, "ERROR: CUDA Device not set.\n");
      return 0;
    }
  }

  //cuFFdotBatch* stkLst = new cuFFdotBatch;

  FOLD // Set up basic slack list parameters from the harmonics  .
  {
    // Copy the basic batch parameters
    memcpy(stkLst, kernel, sizeof(cuFFdotBatch));

    // Copy the actual stacks
    stkLst->stacks = (cuFfdotStack*) malloc(stkLst->noStacks  * sizeof(cuFfdotStack));
    memcpy(stkLst->stacks, kernel->stacks, stkLst->noStacks    * sizeof(cuFfdotStack));
  }

  FOLD // Allocate all device and host memory for the stacks  .
  {
    // Allocate page-locked host memory for input data
    if ( stkLst->flag & CU_INPT_SINGLE ) // TODO: Do a memory check here, ie is the enough
    {
      CUDA_SAFE_CALL(cudaMallocHost((void**) &stkLst->h_iData, stkLst->inpDataSize*stkLst->noSteps ), "Failed to create page-locked host memory plain input data." );

      if ( stkLst->flag & CU_INPT_SINGLE_C ) // Allocate memory for normalisation
        stkLst->h_powers = (float*) malloc(stkLst->hInfos[0].width * sizeof(float));
    }

    FOLD  // Allocate R value lists  .
    {
      rVals*    l;
      rVals**   ll;
      int oSet;

      l  = (rVals*)malloc(sizeof(rVals)*stkLst->noSteps*stkLst->noHarms*3);
      oSet = 0;

      ll = (rVals**)malloc(sizeof(rVals*)*stkLst->noSteps);
      for(int step = 0; step < stkLst->noSteps; step++)
      {
        ll[step] = &l[oSet];
        oSet+= stkLst->noHarms;
      }
      stkLst->rInput  = (rVals***)malloc(sizeof(rVals**));
      *stkLst->rInput = ll;

      ll = (rVals**)malloc(sizeof(rVals*)*stkLst->noSteps);
      for(int step = 0; step < stkLst->noSteps; step++)
      {
        ll[step] = &l[oSet];
        oSet+= stkLst->noHarms;
      }
      stkLst->rSearch  = (rVals***)malloc(sizeof(rVals**));
      *stkLst->rSearch = ll;

      ll = (rVals**)malloc(sizeof(rVals*)*stkLst->noSteps);
      for(int step = 0; step < stkLst->noSteps; step++)
      {
        ll[step] = &l[oSet];
        oSet+= stkLst->noHarms;
      }
      stkLst->rConvld  = (rVals***)malloc(sizeof(rVals**));
      *stkLst->rConvld = ll;
    }

    FOLD // Allocate device Memory for Plain Stack & input data (steps)  .
    {
      CUDA_SAFE_CALL(cudaMemGetInfo ( &free, &total ), "Getting Device memory information");

      if ( (stkLst->inpDataSize + stkLst->plnDataSize + stkLst->pwrDataSize ) * stkLst->noSteps > free )
      {
        // Not enough memory =(

        // NOTE: we could reduce noSteps for this stack, but all batches must be the same size to share the same CFFT plan

        printf("Not enough GPU memory to create any more stacks.\n");
        return 0;
      }
      else
      {
        // Allocate device memory
        CUDA_SAFE_CALL(cudaMalloc((void** )&stkLst->d_iData,        stkLst->inpDataSize*stkLst->noSteps ), "Failed to allocate device memory for kernel stack.");
        CUDA_SAFE_CALL(cudaMalloc((void** )&stkLst->d_plainData,    stkLst->plnDataSize*stkLst->noSteps ), "Failed to allocate device memory for kernel stack.");

        if ( stkLst->flag & FLAG_CUFFTCB_OUT )
        {
          CUDA_SAFE_CALL(cudaMalloc((void** )&stkLst->d_plainPowers,     stkLst->pwrDataSize*stkLst->noSteps ), "Failed to allocate device memory for kernel stack.");
          //stkLst->d_plainPowers = (float*)stkLst->d_plainData; // We can just re-use the plain data <- UMMMMMMMMM? No we can't!!
        }
      }
    }

    FOLD // Allocate device & page-locked host memory for candidate  data  .
    {
      if ( stkLst->flag & CU_OUTP_SINGLE )
      {
        CUDA_SAFE_CALL(cudaMemGetInfo ( &free, &total ), "Getting Device memory information");

        FOLD // Allocate device memory  .
        {
          if ( stkLst->retDataSize*stkLst->noSteps > free )
          {
            // Not enough memory =(
            printf("Not enough GPU memory to create stacks.\n");
            return 0;
          }
          else
          {
            CUDA_SAFE_CALL(cudaMalloc((void** ) &stkLst->d_retData, stkLst->retDataSize*stkLst->noSteps ), "Failed to allocate device memory for return values.");
          }
        }

        FOLD // Allocate page-locked host memory to copy the candidates back to  .
        {
          CUDA_SAFE_CALL(cudaMallocHost((void**) &stkLst->h_retData, stkLst->retDataSize*stkLst->noSteps),"");
          memset(stkLst->h_retData, 0, stkLst->retDataSize*stkLst->noSteps );
        }
      }
    }

    // Create the plains structures
    if ( stkLst->noHarms* sizeof(cuFFdot) > getFreeRamCU() )
    {
      fprintf(stderr, "ERROR: Not enough host memory for search.\n");
      return 0;
    }
    else
    {
      stkLst->plains = (cuFFdot*) malloc(stkLst->noHarms* sizeof(cuFFdot));
      memset(stkLst->plains, 0, stkLst->noHarms* sizeof(cuFFdot));
    }
  }

  FOLD // Set up the batch streams and events  .
  {
    CUDA_SAFE_CALL(cudaStreamCreate(&stkLst->inpStream),"Creating input stream for batch.");
    sprintf(tmpStr,"%i.%i.0.0 stkLst input", stkLst->device, no);
    nvtxNameCudaStreamA(stkLst->inpStream, tmpStr);

    FOLD // Create a streams and events for the stacks
    {
      for (int i = 0; i< stkLst->noStacks; i++)
      {
        cuFfdotStack* cStack  = &stkLst->stacks[i];

        CUDA_SAFE_CALL(cudaStreamCreate(&cStack->inpStream), "Creating input data cnvlStream for stack");
        sprintf(tmpStr,"%i.%i.0.%i Stack Input", stkLst->device, no, i);
        nvtxNameCudaStreamA(cStack->inpStream, tmpStr);
      }

      for (int i = 0; i< stkLst->noStacks; i++)
      {
        cuFfdotStack* cStack  = &stkLst->stacks[i];

        CUDA_SAFE_CALL(cudaStreamCreate(&cStack->cnvlStream), "Creating cnvlStream for stack");
        sprintf(tmpStr,"%i.%i.1.%i Stack Convolve", stkLst->device, no, i);
        nvtxNameCudaStreamA(cStack->cnvlStream, tmpStr);

        CUDA_SAFE_CALL(cudaEventCreateWithFlags(&cStack->prepComp, cudaEventDisableTiming), "Creating input data preparation complete event");
        CUDA_SAFE_CALL(cudaEventCreateWithFlags(&cStack->convComp, cudaEventDisableTiming), "Creating convolution complete event");
        CUDA_SAFE_CALL(cudaEventCreateWithFlags(&cStack->plnComp,  cudaEventDisableTiming), "Creating complex plain creation complete event");

        CUDA_SAFE_CALL(cudaEventRecord(cStack->convComp, cStack->cnvlStream), "Recording convolution complete event");
        CUDA_SAFE_CALL(cudaEventRecord(cStack->convComp, stkLst->inpStream ), "Recording convolution complete event");
        CUDA_SAFE_CALL(cudaEventRecord(cStack->prepComp, cStack->cnvlStream), "Recording convolution complete event");
      }

      if ( 0 )
      {
        for (int i = 0; i< stkLst->noStacks; i++)
        {
          cuFfdotStack* cStack = &stkLst->stacks[i];

          cStack->fftIStream = cStack->inpStream;
          cStack->fftPStream = cStack->cnvlStream;
        }
      }
    }

    CUDA_SAFE_CALL(cudaStreamCreate(&stkLst->strmSearch), "Creating strmSearch for batch.");
    sprintf(tmpStr,"%i.%i.2.0 stkLst search", stkLst->device, no);
    nvtxNameCudaStreamA(stkLst->strmSearch, tmpStr);

    cudaEventCreateWithFlags(&stkLst->iDataCpyComp,   cudaEventDisableTiming  /* || cudaEventBlockingSync */ );
    cudaEventCreateWithFlags(&stkLst->candCpyComp,    cudaEventDisableTiming  /* || cudaEventBlockingSync */ );
    cudaEventCreateWithFlags(&stkLst->normComp,       cudaEventDisableTiming);
    cudaEventCreateWithFlags(&stkLst->searchComp,     cudaEventDisableTiming);
    cudaEventCreateWithFlags(&stkLst->processComp,    cudaEventDisableTiming);

    CUDA_SAFE_CALL(cudaGetLastError(), "Creating streams and events for the batch.");
  }

  FOLD // Setup the pointers for the stacks and plains of this batch  .
  {
    setStkPointers(stkLst);

    /*
    size_t stkStart = 0;
    size_t pwrStart = 0;
    size_t idSiz    = 0;            /// The size in bytes of input data for one stack
    int harm        = 0;

    for (int i = 0; i < stkLst->noStacks; i++)
    {
      // Set stack pointers
      cuFfdotStack* cStack  = &stkLst->stacks[i];
      cStack->d_iData       = &stkLst->d_iData[idSiz];
      cStack->h_iData       = &stkLst->h_iData[idSiz];
      cStack->plains        = &stkLst->plains[harm];
      cStack->kernels       = &stkLst->kernels[harm];
      cStack->d_plainData   = &stkLst->d_plainData[stkStart];
      cStack->d_plainPowers = &stkLst->d_plainPowers[pwrStart];

      // Now set plain pointers
      for (int j = 0; j < cStack->noInStack; j++)
      {
        cuFFdot* cPlain     = &cStack->plains[j];

        if ( (stkLst->flag & FLAG_STP_ROW) || (stkLst->flag & FLAG_STP_PLN) )
        {
          cPlain->d_plainData     = &cStack->d_plainData[   cStack->startR[j]  * stkLst->noSteps * cStack->inpStride ];
          cPlain->d_plainPowers   = &cStack->d_plainPowers[ cStack->startR[j]  * stkLst->noSteps * cStack->pwrStride ];
        }
        else // Note this works for 1 step or FLAG_STP_STK
        {
          cPlain->d_plainData     = &cStack->d_plainData[   cStack->startR[j]  * cStack->inpStride ];
          cPlain->d_plainPowers   = &cStack->d_plainPowers[ cStack->startR[j]  * cStack->pwrStride ];
        }

        cPlain->harmInf     = &cStack->harmInf[j];
        cPlain->d_iData     = &cStack->d_iData[cStack->inpStride*j];
        cPlain->kernel      = &cStack->kernels[j];

        idSiz               += cStack->inpStride * stkLst->noSteps;
        harm++;
      }
      stkStart += cStack->height * cStack->inpStride * stkLst->noSteps ;
      pwrStart += cStack->height * cStack->pwrStride * stkLst->noSteps ;
    }

    setPlainPointers(stkLst);
     */
  }

  /*   // Rather use 1 FFT plan per device  .
  FOLD // Create FFT plans  .
  {
    for (int i = 0; i < stkLst->noStacks; i++)
    {
      cuFfdotStack* cStack  = &stkLst->stacks[i];
      size_t fftSize        = 0;

      FOLD
      {
        int n[]             = {cStack->width};
        int inembed[]       = {cStack->stride* sizeof(fcomplexcu)};
        int istride         = 1;
        int idist           = cStack->stride;
        int onembed[]       = {cStack->stride* sizeof(fcomplexcu)};
        int ostride         = 1;
        int odist           = cStack->stride;

        cufftCreate(&cStack->plnPlan);
        cufftCreate(&cStack->inpPlan);

        CUFFT_SAFE_CALL(cufftPlanMany    (&cStack->plnPlan, 1, n, inembed, istride, idist, onembed, ostride, odist, CUFFT_C2C, cStack->height),     "Creating plan for complex data of stack.");
        //CUFFT_SAFE_CALL(cufftMakePlanMany(cStack->plnPlan,  1, n, inembed, istride, idist, onembed, ostride, odist, CUFFT_C2C, cStack->height, &fftSize),     "Creating plan for complex data of stack.");
        CUFFT_SAFE_CALL(cufftPlanMany    (&cStack->inpPlan, 1, n, inembed, istride, idist, onembed, ostride, odist, CUFFT_C2C, cStack->noInStack),  "Creating plan for input data of stack.");
        //CUFFT_SAFE_CALL(cufftMakePlanMany(cStack->inpPlan,  1, n, inembed, istride, idist, onembed, ostride, odist, CUFFT_C2C, cStack->noInStack, &fftSize),  "Creating plan for input data of stack.");
      }
      CUDA_SAFE_CALL(cudaGetLastError(), "Creating FFT plans for the stacks.");
    }
  }
   */

  FOLD // Create textures for the f-∂f plains  .
  {
    if ( stkLst->flag & FLAG_PLN_TEX )
    {
      cudaChannelFormatDesc channelDesc = cudaCreateChannelDesc(32, 32, 0, 0, cudaChannelFormatKindFloat);

      struct cudaTextureDesc texDesc;
      memset(&texDesc, 0, sizeof(texDesc));
      texDesc.addressMode[0]    = cudaAddressModeClamp;
      texDesc.addressMode[1]    = cudaAddressModeClamp;
      texDesc.readMode          = cudaReadModeElementType;
      texDesc.normalizedCoords  = 0;

      if ( stkLst->flag & FLAG_CUFFTCB_OUT)
        texDesc.filterMode        = cudaFilterModeLinear;
      else
        texDesc.filterMode        = cudaFilterModePoint;

      for (int i = 0; i< stkLst->noStacks; i++)
      {
        cuFfdotStack* cStack = &stkLst->stacks[i];

        cudaResourceDesc resDesc;
        memset(&resDesc, 0, sizeof(resDesc));
        resDesc.resType           = cudaResourceTypePitch2D;
        resDesc.res.pitch2D.desc  = channelDesc;

        for (int j = 0; j< cStack->noInStack; j++)
        {
          cuFFdot* cPlain = &cStack->plains[j];

          resDesc.res.pitch2D.height          = cPlain->harmInf->height * stkLst->noSteps ;
          resDesc.res.pitch2D.width           = cPlain->harmInf->width;

          if ( stkLst->flag & FLAG_CUFFTCB_OUT )
          {
            if      ( stkLst->flag & FLAG_STP_ROW )
            {
              resDesc.res.pitch2D.height          = cPlain->harmInf->height;
              resDesc.res.pitch2D.width           = cPlain->harmInf->width * stkLst->noSteps;

              resDesc.res.pitch2D.devPtr          = cPlain->d_plainPowers;
              resDesc.res.pitch2D.pitchInBytes    = cStack->pwrStride * sizeof(float)*stkLst->noSteps;
            }
            else if ( stkLst->flag & FLAG_STP_PLN )
            {
              resDesc.res.pitch2D.height          = cPlain->harmInf->height * stkLst->noSteps ;
              resDesc.res.pitch2D.width           = cPlain->harmInf->width;

              resDesc.res.pitch2D.devPtr          = cPlain->d_plainPowers;
              resDesc.res.pitch2D.pitchInBytes    = cStack->pwrStride * sizeof(float);
            }
            else
            {
              // Error
            }
          }
          else
          {
            resDesc.res.pitch2D.devPtr        = cPlain->d_plainData;
            resDesc.res.pitch2D.pitchInBytes  = cStack->inpStride * sizeof(fcomplex);
          }

          CUDA_SAFE_CALL(cudaCreateTextureObject(&cPlain->datTex, &resDesc, &texDesc, NULL), "Creating texture from the plain data.");
        }
      }
      CUDA_SAFE_CALL(cudaGetLastError(), "Creating textures from the plain data.");

    }
  }

  FOLD // Set up CUFFT call back stuff  .
  {
    if ( (stkLst->flag & FLAG_CUFFTCB_INP) || (stkLst->flag & FLAG_CUFFTCB_OUT) )
    {
      if ( stkLst->flag & FLAG_CUFFTCB_INP )
      {
        for (int i = 0; i < stkLst->noStacks; i++)
        {
          cuFfdotStack* cStack  = &stkLst->stacks[i];
          CUDA_SAFE_CALL(cudaMalloc((void **)&cStack->d_cinf, sizeof(fftCnvlvInfo)),"Malloc Device memory for CUFFT call-back structure");

          size_t heights = 0;

          fftCnvlvInfo h_inf;

          h_inf.noSteps         = stkLst->noSteps;
          h_inf.stride          = cStack->inpStride;
          h_inf.width           = cStack->width;
          h_inf.noPlains        = cStack->noInStack;
          h_inf.d_plainPowers   = cStack->d_plainPowers;

          for (int i = 0; i < cStack->noInStack; i++)     // Loop over plains to determine where they start
          {
            h_inf.d_idata[i]    = cStack->plains[i].d_iData;
            h_inf.d_kernel[i]   = cStack->kernels[i].d_kerData;
            h_inf.heights[i]    = cStack->harmInf[i].height;
            h_inf.top[i]        = heights;
            heights            += cStack->harmInf[i].height;
          }

          for (int i = cStack->noInStack; i < MAX_STKSZ; i++ )
          {
            h_inf.heights[i]    = cStack->harmInf[i].height;
            printf("top %02i: %6li\n", i, heights);
          }

          // Copy host memory to device
          CUDA_SAFE_CALL(cudaMemcpy(cStack->d_cinf, &h_inf, sizeof(fftCnvlvInfo), cudaMemcpyHostToDevice),"Copy to device");
        }
      }

      copyCUFFT_LD_CB();
    }
  }

  return stkLst->noSteps;
}

void freeBatch(cuFFdotBatch* stkLst)
{
  FOLD // Allocate all device and host memory for the stacks  .
  {
    // Allocate page-locked host memory for input data
    if ( stkLst->flag & CU_INPT_SINGLE ) // TODO: Do a memory check here, ie is the enough
    {
      CUDA_SAFE_CALL(cudaFreeHost(stkLst->h_iData ), "Failed to create page-locked host memory plain input data." );

      if ( stkLst->flag & CU_INPT_SINGLE_C ) // Allocate memory for normalisation
        free(stkLst->h_powers);
    }

    FOLD // Allocate device Memory for Plain Stack & input data (steps)  .
    {
      // Allocate device memory
      CUDA_SAFE_CALL(cudaFree(stkLst->d_iData ), "Failed to allocate device memory for kernel stack.");
      CUDA_SAFE_CALL(cudaFree(stkLst->d_plainData ), "Failed to allocate device memory for kernel stack.");

      if ( stkLst->flag & FLAG_CUFFTCB_OUT )
      {
        CUDA_SAFE_CALL(cudaFree(stkLst->d_plainPowers), "Failed to allocate device memory for kernel stack.");
      }
    }

    FOLD // Allocate device & page-locked host memory for candidate  data  .
    {
      if ( stkLst->flag & CU_OUTP_SINGLE )
      {
        CUDA_SAFE_CALL(cudaFree(stkLst->d_retData     ), "Failed to allocate device memory for return values.");
        CUDA_SAFE_CALL(cudaFreeHost(stkLst->h_retData ),"");
      }
    }

    // Create the plains structures
    free(stkLst->plains);
  }

  FOLD // Create textures for the f-∂f plains  .
  {
    if ( stkLst->flag & FLAG_PLN_TEX )
    {

      for (int i = 0; i< stkLst->noStacks; i++)
      {
        cuFfdotStack* cStack = &stkLst->stacks[i];

        for (int j = 0; j< cStack->noInStack; j++)
        {
          cuFFdot* cPlain = &cStack->plains[j];

          CUDA_SAFE_CALL(cudaDestroyTextureObject(cPlain->datTex), "Creating texture from the plain data.");
        }
      }
      CUDA_SAFE_CALL(cudaGetLastError(), "Creating textures from the plain data.");
    }
  }

  FOLD // Set up CUFFT call back stuff
  {
    if ( (stkLst->flag & FLAG_CUFFTCB_INP) || (stkLst->flag & FLAG_CUFFTCB_OUT) )
    {
      if ( stkLst->flag & FLAG_CUFFTCB_INP )
      {
        for (int i = 0; i < stkLst->noStacks; i++)
        {
          cuFfdotStack* cStack  = &stkLst->stacks[i];
          CUDA_SAFE_CALL(cudaFree(cStack->d_cinf),"Malloc Device memory for CUFFT call-back structure");
        }
      }
    }
  }

  //free(stkLst);
}

/*
fcomplexcu* prepFFTdata(fcomplexcu *data, uint len, uint len2, cuFfdot* ffdotPlain)
{
  dim3 dimBlock, dimGrid;

  // Memory allocation
  if (true)
  {
    if (ffdotPlain->dInpFFT== 0)
    {
      ffdotPlain->inputLen = len+ 100;  // Buffer with 10
      CUDA_SAFE_CALL(cudaMalloc((void ** ) &ffdotPlain->dInpFFT, (ffdotPlain->inputLen)* sizeof(fcomplexcu)), "Failed to allocate device memory for input data.");
      CUDA_SAFE_CALL(cudaGetLastError(), "Error allocating memory for input data\n");
    }
    else if (len> ffdotPlain->inputLen)
    {
      printf("ERROR: allocated memory for input fft is to small\n");
      return 0;
    }

    if (ffdotPlain->dSpreadFFT== 0)
    {
      ffdotPlain->spreadLen = len2+ 100;
      CUDA_SAFE_CALL(cudaMalloc((void ** ) &ffdotPlain->dSpreadFFT, ffdotPlain->spreadLen* sizeof(fcomplexcu)), "Failed to allocate device memory for spread input.");
      CUDA_SAFE_CALL(cudaGetLastError(), "Error allocating memory for spread input data\n");
    }
    else if (len2> ffdotPlain->spreadLen)
    {
      printf("ERROR: allocated memory for input fft is to small\n");
      return 0;
    }

    if (ffdotPlain->dPowers== 0)
    {
      ffdotPlain->powersLen = len+ 100;
      CUDA_SAFE_CALL(cudaMalloc((void ** ) &ffdotPlain->dPowers, ffdotPlain->powersLen* sizeof(float)), "Failed to allocate device memory for input h_powers.");
      CUDA_SAFE_CALL(cudaGetLastError(), "Error allocating memory for input h_powers.\n");
    }
    else if (len> ffdotPlain->powersLen)
    {
      printf("ERROR: allocated memory for ffdot h_powers is to small\n");
      return 0;
    }

    CUDA_SAFE_CALL(cudaGetLastError(), "Error allocating memory for input data\n");

  }

  CUDA_SAFE_CALL(cudaMemcpyAsync(ffdotPlain->dInpFFT, data, len* sizeof(fcomplexcu), cudaMemcpyHostToDevice, ffdotPlain->stream), "Failed to copy data to device");
  CUDA_SAFE_CALL(cudaStreamSynchronize(ffdotPlain->stream), "ERROR: copying data to device");

  FOLD // Powers
  {
    dimBlock.x = BLOCK1DSIZE;
    dimBlock.y = 1;

    dimGrid.x = ceil(len/ (float) (dimBlock.x));
    dimGrid.y = 1;

    calculatePowers<<<dimGrid, dimBlock, 0, ffdotPlain->stream>>>(ffdotPlain->dInpFFT, ffdotPlain->dPowers, len);

    // Wait for completion
    CUDA_SAFE_CALL(cudaStreamSynchronize(ffdotPlain->stream), "Error after kernel launch");

    // Run message
    CUDA_SAFE_CALL(cudaGetLastError(), "Error at kernel launch (calculatePowers)");
  }

  FOLD // Find median
  {
    //const uint maxInBlk = 8192;
    uint blockSz = BS_DIM;
    //blockSz = 576;

    if (len<= BS_MAX)  // One block
    {
      if (len/ 2.0< blockSz)
        dimBlock.x = ceil(len/ 2.0);
      else
        dimBlock.x = blockSz;

      dimBlock.y = 1;

      dimGrid.x = 1;
      dimGrid.y = 1;

      uint noBatch = ceilf(len/ 2.0/ dimBlock.x);    // Number of comparisons each thread must do

      median1Block<<<dimGrid, dimBlock, 0, ffdotPlain->stream>>>((float*)ffdotPlain->dPowers, len, &ffdotPlain->dPowers[len], noBatch);
      //median1Block<<<dimGrid, dimBlock>>>(ffdotPlain->dPowers, len, &ffdotPlain->dPowers[len]);

      // Wait for completion
      CUDA_SAFE_CALL(cudaStreamSynchronize(ffdotPlain->stream),"Error after median1Block");

      // Run message
      CUDA_SAFE_CALL(cudaGetLastError(), "Error at kernel launch (median1Block)");
    }
    else
    {
      int noBB = 1;
      float noBlocks = len/ 2.0/ BS_DIM/ noBB;
      if (noBlocks> 8)
      {
        noBB++;
        noBlocks = len/ 2.0/ BS_DIM/ noBB;
      }
      dimBlock.x = BS_DIM;

      dimGrid.x = ceil(noBlocks);
      dimGrid.y = 1;

      if (ffdotPlain->ffdotMedData== 0)
      {
        CUDA_SAFE_CALL(cudaMalloc((void ** ) &ffdotPlain->ffdotMedData, 3* (dimGrid.x+ 5)* sizeof(float)), "Failed to allocate device memory for.");
      }

      sortNBlock<<<dimGrid, dimBlock, 0, ffdotPlain->stream>>>(ffdotPlain->dPowers, len, ffdotPlain->ffdotMedData);
      CUDA_SAFE_CALL(cudaGetLastError(), "Error at kernel launch");
      //CUDA_SAFE_CALL(cudaStreamSynchronize(ffdotPlain->cnvlStream),"Error after kernel launch");

      selectMedianCands<<<dimGrid, dimBlock, (BS_DIM* 2+ 200)* sizeof(float), ffdotPlain->stream>>>(ffdotPlain->dPowers, len, ffdotPlain->ffdotMedData);
      CUDA_SAFE_CALL(cudaGetLastError(), "Error at kernel launch");
      //CUDA_SAFE_CALL(cudaStreamSynchronize(ffdotPlain->cnvlStream),"Error after kernel launch");

      int bPlocks = dimGrid.x;
      dimGrid.x = 1;

      medFromMedians<<<dimGrid, dimBlock, (BS_DIM* 2+ 400)* sizeof(float), ffdotPlain->stream>>>(ffdotPlain->dPowers, len, ffdotPlain->ffdotMedData, bPlocks, &ffdotPlain->dPowers[len]);
      CUDA_SAFE_CALL(cudaGetLastError(), "Error at kernel launch");
      //CUDA_SAFE_CALL(cudaStreamSynchronize(ffdotPlain->stream),"Error after kernel launch");

    }
  }

  FOLD // Spread and normalise
  {
    // Wait for completion
    CUDA_SAFE_CALL(cudaStreamSynchronize(ffdotPlain->stream),"Error after median1Block");

    dimBlock.x = BLOCK1DSIZE;
    dimGrid.x = ceil(len2/ 2/ (float) (dimBlock.x));  // this will zero pad the end

    devideAndSpreadFFT<<<dimGrid, dimBlock, 0, ffdotPlain->stream>>>(ffdotPlain->dInpFFT, len, ffdotPlain->dSpreadFFT, len2, &ffdotPlain->dPowers[len]);

    // Run message
    CUDA_SAFE_CALL(cudaGetLastError(), "Error at kernel launch");

    // Wait for cadd_and_searchompletion
    //CUDA_SAFE_CALL(cudaStreamSynchronize(ffdotPlain->stream),"Error after kernel launch");
  }

  FOLD // 1D FFT result
  {
    cufftResult cufftRes = CUFFT_SUCCESS;

    // Make plan
    if ((ffdotPlain->plan1D)== 0)
    {
      cufftRes = cufftPlan1d(&ffdotPlain->plan1D, len2, CUFFT_C2C, 1);
      if (cufftRes!= CUFFT_SUCCESS)
      {
        fprintf(stderr, "ERROR: Error creating CUFFT plan\n");
        exit(EXIT_FAILURE);
      }

      cufftRes = cufftSetStream(ffdotPlain->plan1D, ffdotPlain->stream);
      if (cufftRes!= CUFFT_SUCCESS)
      {
        fprintf(stderr, "ERROR: Error associating a CUFFT plan with cnvlStream\n");
        exit(EXIT_FAILURE);
      }
    }

    cufftRes = cufftExecC2C(ffdotPlain->plan1D, (cufftComplex *) ffdotPlain->dSpreadFFT, (cufftComplex *) ffdotPlain->dSpreadFFT, CUFFT_FORWARD);
    if (cufftRes!= CUFFT_SUCCESS)
    {
      fprintf(stderr, "ERROR: Error executing CUFFT plan\n");
      exit(EXIT_FAILURE);
    }
  }

  return ffdotPlain->dSpreadFFT;
}
*/

/*
float* init_kernels_cu(int maxZ, int fftlen)
{
  float* dArrayA = NULL;
  size_t pitch;
  size_t yy = (maxZ+ 1);
  size_t row = fftlen* sizeof(cufftComplex);

  cufftHandle plan;
  // Variables to describe the blocks and grid
  dim3 dimBlock, dimGrid;
  //int threadsPerBlock, blocksPerGrid;

  cudaError_t result;
  cufftResult cufftRes;

  //cudaMalloc ( ( void ** ) &dArrayA, (maxZ*2+1) * fftlen * sizeof ( float )*2 );
  //cudaMalloc((void**)&data, sizeof(cufftComplex)*NX*BATCH);

  result = cudaMallocPitch((void **) &dArrayA, &pitch, row, yy);
  if (result!= cudaSuccess)
  {
    fprintf(stderr, "ERROR: Error allocating pitched memory %s\n", cudaGetErrorString(result));
    exit(EXIT_FAILURE);
  }

  dimBlock.x = BLOCKSIZE;  // in my experience 16 is almost always best (half warp)
  dimBlock.y = BLOCKSIZE;  // in my experience 16 is almost always best (half warp)
  //threadsPerBlock = dimBlock.x * dimBlock.y * dimBlock.z;

  dimGrid.x = ceil(fftlen/ (float) dimBlock.x);
  dimGrid.y = ceil(yy/ (float) dimBlock.y);
  //blocksPerGrid = dimGrid.x * dimGrid.y * dimGrid.z;

  //printf ( "Calling kernel \n" );

  //init_kernels <<< dimGrid, dimBlock>>> ( dArrayA, maxZ, fftlen);

  FOLD
  {
    cufftComplex *data = (cufftComplex *) dArrayA;
    cufftRes = cufftPlan1d(&plan, fftlen, CUFFT_C2C, yy);
    if (cufftRes!= CUFFT_SUCCESS)
    {
      fprintf(stderr, "ERROR: Error creating CUFFT plan\n");
      exit(EXIT_FAILURE);
    }

    cufftRes = cufftExecC2C(plan, data, data, CUFFT_FORWARD);
    if (cufftRes!= CUFFT_SUCCESS)
    {
      fprintf(stderr, "ERROR: Error executing CUFFT plan\n");
      exit(EXIT_FAILURE);
    }
  }

  FOLD // Run message
  {
    result = cudaGetLastError();  // This determines whether the kernel was launched

    if (result== cudaSuccess)
    {
      //printf ( "Running kernel ..." );
    }
    else
    {
      fprintf(stderr, "ERROR: Error at kernel launch %s\n", cudaGetErrorString(result));
      exit(EXIT_FAILURE);
    }
  }

  FOLD
  {
    result = cudaDeviceSynchronize();  // This will return when the kernel computation is complete, remember asynchronous execution
    // Complete message
    if (result== cudaSuccess)
    {
      //printf ( " Complete.\n" );
    }
    else
      fprintf(stderr, "\nERROR: Error after kernel launch %s\n", cudaGetErrorString(result));
  }

  float* dArrayA_h = (float*) malloc(yy* row);
  cudaMemcpy(dArrayA_h, dArrayA, yy* row, cudaMemcpyDeviceToHost);

  return dArrayA_h;
}
 */

/*
void drawPlainPowers(cuFfdot* ffdotPlain, char* name)
{
  CUDA_SAFE_CALL(cudaStreamSynchronize(ffdotPlain->stream), "Error after kernel launch");
  CUDA_SAFE_CALL(cudaDeviceSynchronize(), "Error after kernel launch");

  float *tmpp = (float*) malloc(ffdotPlain->ffPowWidth* ffdotPlain->ffPowHeight* sizeof(float));
  //float DestS   = ffdotPlain->ffPowWidth*sizeof(float);
  //float SourceS = ffdotPlain->ffPowStride;
  CUDA_SAFE_CALL(cudaMemcpy2D(tmpp, ffdotPlain->ffPowWidth* sizeof(float), ffdotPlain->ffdotPowers, ffdotPlain->ffPowStride* sizeof(float), ffdotPlain->ffPowWidth* sizeof(float), ffdotPlain->ffPowHeight, cudaMemcpyDeviceToHost), "Failed to copy data from device to host");

  int il;
  printf("GPU\n");
  for (il = 0; il< 10; il++)
    printf("%02i %10.5f\n", il, tmpp[il]);

  //draw2DArray6(name, tmpp, ffdotPlain->ffPowWidth, ffdotPlain->ffPowHeight, 4096, 1602);
  free(tmpp);
}
*/

void drawPlainCmplx(fcomplexcu* ffdotPlain, char* name, int stride, int height)
{
  float *tmpp = (float*) malloc(stride * height * sizeof(fcomplexcu));
  //float DestS   = ffdotPlain->ffPowWidth*sizeof(float);
  //float SourceS = ffdotPlain->ffPowStride;
  CUDA_SAFE_CALL(cudaMemcpy2D(tmpp, stride * sizeof(fcomplexcu), ffdotPlain, stride * sizeof(fcomplexcu), stride * sizeof(fcomplexcu), height, cudaMemcpyDeviceToHost), "Failed to copy data from device to host");

  //draw2DArray(name, tmpp, stride*2, height);
  free(tmpp);
}

/*
void  drawPlainCmlx(cuFfdot* ffdotPlain, char* name)
{
  //int numtocopy = hInf[harm].width - 2 * hInf[harm].halfWidth*ACCEL_NUMBETWEEN;
  //if (numrs < numtocopy)
  //  numtocopy = numrs;

  CUDA_SAFE_CALL(cudaStreamSynchronize(ffdotPlain->stream), "Error after kernel launch");
  CUDA_SAFE_CALL(cudaDeviceSynchronize(), "Error after kernel launch");

  float *tmpp = (float*) malloc(ffdotPlain->ffdotWidth* ffdotPlain->ffdotHeight* sizeof(fcomplexcu));
  float DestS = ffdotPlain->ffdotWidth* sizeof(fcomplexcu);
  //float SourceS = ffdotPlain->ffdotStride;
  CUDA_SAFE_CALL(cudaMemcpy2D(tmpp, DestS, ffdotPlain->ffdot, ffdotPlain->ffdotStride* sizeof(fcomplexcu), DestS, ffdotPlain->ffdotHeight, cudaMemcpyDeviceToHost), "Failed to copy data from device to host");

  //draw2DArray6(name, tmpp, ffdotPlain->ffdotWidth* 2, ffdotPlain->ffdotHeight, 500, 500);
  free(tmpp);
}
*/

/*
void CPU_Norm_Spread(cuFFdotBatch* plains, double searchRLow, double searchRHi, int norm_type, fcomplexcu* fft)
{
  nvtxRangePush("CPU_Norm_Spread");

  int       lobin, hibin, binoffset, numdata, nice_numdata, numrs;
  double    drlo, drhi;

  int harm = 0;
  int sz = 0;

  FOLD // Copy raw input fft data to device
  {
    // Write data to page locked memory
    for (int ss = 0; ss < plains->noStacks; ss++)
    {
      cuFfdotStack* cStack = &plains->stacks[ss];

      for (int si = 0; si < cStack->noInStack; si++)
      {
        cuHarmInfo* cHInfo  = &plains->hInfos[harm];      // The current harmonic we are working on

        rVals* rVal = &((*plains->rInput)[step][harm]);

        if ( norm_type== 0 )  // Normal normalise
        {
          double norm;    /// The normalising factor

          nvtxRangePush("Powers");
          for (int ii = 0; ii < numdata; ii++)
          {
            if ( lobin+ii < 0 )
            {
              plains->h_powers[ii] = 0;
            }
            else
              plains->h_powers[ii] = POWERCU(fft[(int)lobin+ii].r, fft[(int)lobin+ii].i);
          }
          nvtxRangePop();

          if ( DBG_INP01 )
          {
            float* data = (float*)&fft[(int)lobin];
            int gx;
            printf("\nGPU Input Data RAW FFTs [ Half width: %i  lowbin: %i  drlo: %.2f ] \n", binoffset, lobin, drlo);

            for ( gx = 0; gx < 10; gx++)
              printf("%.4f ",((float*)data)[gx]);
            printf("\n");
          }

          nvtxRangePush("Median");
          norm = 1.0 / sqrt(median(plains->h_powers, (numdata))/ log(2.0));                   /// NOTE: This is the same methoud as CPU version
          //norm = 1.0 / sqrt(median(&plains->h_powers[start], (numdata-start))/ log(2.0));       /// NOTE: This is a slightly better methoud in my opinion
          nvtxRangePop();

          // Normalise and spread
          nvtxRangePush("Write");
          for (int ii = 0; ii < numdata && ii * ACCEL_NUMBETWEEN < cStack->inpStride; ii++)
          {
            if ( lobin+ii < 0 )
            {
              plains->h_iData[sz + ii * ACCEL_NUMBETWEEN].r = 0;
              plains->h_iData[sz + ii * ACCEL_NUMBETWEEN].i = 0;
            }
            else
            {
              if (ii * ACCEL_NUMBETWEEN > cStack->inpStride)
              {
                fprintf(stderr, "ERROR: nice_numdata is greater that width.\n");
                exit(EXIT_FAILURE);
              }
              plains->h_iData[sz + ii * ACCEL_NUMBETWEEN].r = fft[(int)lobin+ ii].r * norm;
              plains->h_iData[sz + ii * ACCEL_NUMBETWEEN].i = fft[(int)lobin+ ii].i * norm;
            }
          }
          nvtxRangePop();
        }
        else                // or double-tophat normalisation
        {
          // Do the actual copy
          //memcpy(plains->h_powers, &fft[lobin], numdata * sizeof(fcomplexcu) );

          //  new-style running double-tophat local-power normalization
          float *loc_powers;

          //powers = gen_fvect(nice_numdata);
          for (int ii = 0; ii< nice_numdata; ii++)
          {
            plains->h_powers[ii] = POWERCU(fft[(int)lobin+ii].r, fft[(int)lobin+ii].i);
          }
          loc_powers = corr_loc_pow(plains->h_powers, nice_numdata);

          //memcpy(&plains->h_iData[sz], &fft[lobin], nice_numdata * sizeof(fcomplexcu) );

          for (int ii = 0; ii< numdata; ii++)
          {
            float norm = invsqrt(loc_powers[ii]);

            plains->h_iData[sz + ii * ACCEL_NUMBETWEEN].r = fft[(int)lobin+ ii].r* norm;
            plains->h_iData[sz + ii * ACCEL_NUMBETWEEN].i = fft[(int)lobin+ ii].i* norm;
          }

          vect_free(loc_powers);  // I hate doing this!!!
        }

        // I tested doing the FFT's on the CPU and its drastically faster doing it on the GPU, and can often be done synchronously
        //nvtxRangePush("CPU FFT");
        //COMPLEXFFT((fcomplex *)&plains->h_iData[sz], numdata*ACCEL_NUMBETWEEN, -1);
        //nvtxRangePop();

        sz += cStack->inpStride;
        harm++;
      }
    }
  }

  nvtxRangePop();
}
*/

void CPU_Norm_Spread(cuFFdotBatch* plains, double* searchRLow, double* searchRHi, int norm_type, fcomplexcu* fft)
{
  nvtxRangePush("CPU_Norm_Spread_mstep");

  int harm = 0;

  FOLD // Copy raw input fft data to device
  {
    for (int stack = 0; stack < plains->noStacks; stack++)
    {
      cuFfdotStack* cStack = &plains->stacks[stack];
      int sz = 0;
      for (int si = 0; si < cStack->noInStack; si++)
      {
        cuHarmInfo* cHInfo  = &plains->hInfos[harm];      // The current harmonic we are working on

        for (int step = 0; step < plains->noSteps; step++)
        {
          if ( !(searchRLow[step] == 0 &&  searchRHi[step] == 0) )
          {
            rVals* rVal = &((*plains->rInput)[step][harm]);

            if ( norm_type== 0 )  // Normal normalise
            {
              double norm;    /// The normalising factor

              nvtxRangePush("Powers");
              for (int ii = 0; ii < rVal->numdata; ii++)
              {
                if ( rVal->lobin+ii < 0 || rVal->lobin+ii  >= plains->SrchSz->searchRHigh ) // Zero Pad
                {
                  plains->h_powers[ii] = 0;
                }
                else
                  plains->h_powers[ii] = POWERCU(fft[rVal->lobin+ii].r, fft[rVal->lobin+ii].i);
              }
              nvtxRangePop();

              if ( DBG_INP01 )
              {
                float* data = (float*)&fft[rVal->lobin];
                int gx;
                printf("\nGPU Input Data RAW FFTs [ Half width: %i  lowbin: %i  drlo: %.2f ] \n", cHInfo->halfWidth, rVal->lobin, rVal->drlo);

                for ( gx = 0; gx < 10; gx++)
                  printf("%.4f ",((float*)data)[gx]);
                printf("\n");
              }

              nvtxRangePush("Median");
              norm = 1.0 / sqrt(median(plains->h_powers, (rVal->numdata))/ log(2.0));                       /// NOTE: This is the same method as CPU version
              //norm = 1.0 / sqrt(median(&plains->h_powers[start], (rVal->numdata-start))/ log(2.0));       /// NOTE: This is a slightly better method (in my opinion)
              nvtxRangePop();

              // Normalise and spread
              nvtxRangePush("Write");
              for (int ii = 0; ii < rVal->numdata && ii * ACCEL_NUMBETWEEN < cStack->inpStride; ii++)
              {
                if ( rVal->lobin+ii < 0  || rVal->lobin+ii  >= plains->SrchSz->searchRHigh )  // Zero Pad
                {
                  cStack->h_iData[sz + ii * ACCEL_NUMBETWEEN].r = 0;
                  cStack->h_iData[sz + ii * ACCEL_NUMBETWEEN].i = 0;
                }
                else
                {
                  if (ii * ACCEL_NUMBETWEEN > cStack->inpStride)
                  {
                    fprintf(stderr, "ERROR: nice_numdata is greater that width.\n");
                    exit(EXIT_FAILURE);
                  }

                  cStack->h_iData[sz + ii * ACCEL_NUMBETWEEN].r = fft[rVal->lobin+ ii].r * norm;
                  cStack->h_iData[sz + ii * ACCEL_NUMBETWEEN].i = fft[rVal->lobin+ ii].i * norm;
                }
              }
              nvtxRangePop();
            }
            else                  // or double-tophat normalisation
            {
              int nice_numdata = next2_to_n_cu(rVal->numdata);  // for FFTs

              if ( nice_numdata > cStack->width )
              {
                fprintf(stderr, "ERROR: nice_numdata is greater that width.\n");
                //exit(EXIT_FAILURE);
              }

              // Do the actual copy
              //memcpy(plains->h_powers, &fft[lobin], numdata * sizeof(fcomplexcu) );

              //  new-style running double-tophat local-power normalization
              float *loc_powers;

              //powers = gen_fvect(nice_numdata);
              for (int ii = 0; ii< nice_numdata; ii++)
              {
                plains->h_powers[ii] = POWERCU(fft[rVal->lobin+ii].r, fft[rVal->lobin+ii].i);
              }
              loc_powers = corr_loc_pow(plains->h_powers, nice_numdata);

              //memcpy(&plains->h_iData[sz], &fft[lobin], nice_numdata * sizeof(fcomplexcu) );

              for (int ii = 0; ii < rVal->numdata; ii++)
              {
                float norm = invsqrt(loc_powers[ii]);

                plains->h_iData[sz + ii * ACCEL_NUMBETWEEN].r = fft[rVal->lobin+ ii].r* norm;
                plains->h_iData[sz + ii * ACCEL_NUMBETWEEN].i = fft[rVal->lobin+ ii].i* norm;
              }

              vect_free(loc_powers);  // I hate doing this!!!
            }

            // I tested doing the FFT's on the CPU and its drastically faster doing it on the GPU, and can often be done synchronously -- Chris L
            //nvtxRangePush("CPU FFT");
            //COMPLEXFFT((fcomplex *)&plains->h_iData[sz], numdata*ACCEL_NUMBETWEEN, -1);
            //nvtxRangePop();
          }

          sz += cStack->inpStride;
        }
        harm++;
      }
    }
  }

  nvtxRangePop();
}

/*
void setStackRVals(cuFFdotBatch* plains, double* searchRLow, double* searchRHi)
{
  int       hibin, binoffset;
  double    drlo, drhi;

  int lobin;      /// The first bin to copy from the the input fft ( serachR scaled - halfwidth )
  int numdata;    /// The number of input fft points to read
  int numrs;      /// The number of good bins in the plain ( expanded units )

  FOLD // Copy raw input fft data to device
  {
    printf("                      |                       |                        |                       |                      \n" );

    for (int harm = 0; harm < plains->noHarms; harm++)
    {
      cuHarmInfo* cHInfo    = &plains->hInfos[harm];      // The current harmonic we are working on
      cuFFdot* cPlain       = &plains->plains[harm];      //

      binoffset             = cHInfo->halfWidth;          ///

      for (int step = 0; step < plains->noSteps; step++)
      {
        drlo                = calc_required_r_gpu(cHInfo->harmFrac, searchRLow[step]);
        drhi                = calc_required_r_gpu(cHInfo->harmFrac, searchRHi[step] );

        lobin               = (int) floor(drlo) - binoffset;
        hibin               = (int) ceil(drhi)  + binoffset;

        numdata             = hibin - lobin + 1;
        numrs               = (int) ((ceil(drhi) - floor(drlo)) * ACCEL_RDR + DBLCORRECT) + 1;

        if( step == 1 )
        {
          double ExBin = searchRLow[step]*((float)ACCEL_RDR)*cHInfo->harmFrac ;

          double ExBinR = floor( ExBin / 2.0) * 2.0 ;
          double BsBinR = ExBinR / 2.0 ;
          printf("searchR: %11.2f  |   drlo: %11.2f   |   ExBin: %11.2f   |   ExBinR: %9.0f   |   BsBinR: %11.2f\n", searchRLow[step]*cHInfo->harmFrac, drlo, ExBin, ExBinR, BsBinR   );
        }

        if (harm == 0)
          numrs = plains->accelLen;
        else if (numrs % ACCEL_RDR)
          numrs = (numrs / ACCEL_RDR + 1) * ACCEL_RDR;

        int numtocopy = cHInfo->width - 2 * cHInfo->halfWidth * ACCEL_NUMBETWEEN;
        if (numrs < numtocopy)
          numtocopy = numrs;

        cPlain->searchRlowPrev[step]  = cPlain->searchRlow[step];
        cPlain->searchRlow[step]      = searchRLow[step];
        cPlain->numrs[step]           = numrs;
        cPlain->ffdotPowWidth[step]   = numtocopy;
        cPlain->fullRLow[step]        = lobin;
        cPlain->rLow[step]            = drlo;
        cPlain->numInpData[step]      = numdata;
      }
    }
    //printf("searchR: %11.2f  |   drlo: %11.2f   |   ExBin: %11.2f   |   ExBinR: %9.0f   |   BsBinR: %11.2f\n", searchRLow[step]*cHInfo->harmFrac, drlo, ExBin, ExBinR, BsBinR   );
    printf("                      |                       |                        |                       |                      \n" );
  }
}
*/

void setStackRVals(cuFFdotBatch* plains, double* searchRLow, double* searchRHi)
{
  int       hibin, binoffset;
  double    drlo, drhi;

  int lobin;      /// The first bin to copy from the the input fft ( serachR scaled - halfwidth )
  int numdata;    /// The number of input fft points to read
  int numrs;      /// The number of good bins in the plain ( expanded units )

  printf("                      |                       |                        |                       |                      \n" );

  for (int harm = 0; harm < plains->noHarms; harm++)
  {
    cuHarmInfo* cHInfo    = &plains->hInfos[harm];      // The current harmonic we are working on
    binoffset             = cHInfo->halfWidth;          //

    for (int step = 0; step < plains->noSteps; step++)
    {
      rVals* rVal         = &((*plains->rInput)[step][harm]);

      drlo                = calc_required_r_gpu(cHInfo->harmFrac, searchRLow[step]);
      drhi                = calc_required_r_gpu(cHInfo->harmFrac, searchRHi[step] );

      lobin               = (int) floor(drlo) - binoffset;
      hibin               = (int) ceil(drhi)  + binoffset;

      numdata             = hibin - lobin + 1;
      numrs               = (int) ((ceil(drhi) - floor(drlo)) * ACCEL_RDR + DBLCORRECT) + 1;

      if (harm == 0)
        numrs = plains->accelLen;
      else if (numrs % ACCEL_RDR)
        numrs = (numrs / ACCEL_RDR + 1) * ACCEL_RDR;

      rVal->drlo          = drlo;
      rVal->lobin         = lobin;
      rVal->numrs         = numrs;
      rVal->numdata       = numdata;
      rVal->expBin        = (lobin+binoffset)*ACCEL_RDR;

      if( step == 1 )
      {
        double ExBin = searchRLow[step]*((float)ACCEL_RDR)*cHInfo->harmFrac ;

        double ExBinR = floor( ExBin / 2.0) * 2.0 ;
        double BsBinR = ExBinR / 2.0 ;
        printf("searchR: %11.2f  |   drlo: %11.2f   |   ExBin: %11.2f   |   ExBinR: %9.0f   |   BsBinR: %11lli\n", searchRLow[step]*cHInfo->harmFrac, drlo, ExBin, ExBinR, rVal->expBin   );
      }
    }
  }
  printf("                      |                       |                        |                       |                      \n" );

  TMP
}

void cycleRlists(cuFFdotBatch* plains)
{
  rVals*** tmp    = plains->rSearch;

  plains->rSearch = plains->rConvld;
  plains->rConvld = plains->rInput;
  plains->rInput  = tmp;
}

/** Initialise input data for a f-∂f plain(s)  ready for convolution  .
 * This:
 *  Normalises the chunk of input data
 *  Spreads it (interbinning)
 *  FFT it ready for convolution
 *
 * @param plains      The plains
 * @param searchRLow  The index of the low  R bin (1 value for each step)
 * @param searchRHi   The index of the high R bin (1 value for each step)
 * @param norm_type   The type of normalisation to perform
 * @param fft         The fft
 */
void initInput(cuFFdotBatch* batch, double* searchRLow, double* searchRHi, int norm_type, fcomplexcu* fft)
{
  //printf("Input\n");

  iHarmList lengths;
  iHarmList widths;
  cHarmList d_iDataList;
  cHarmList d_fftList;

  //int sz = 0;
  //int lobin, hibin, binoffset, numdata, numrs;
  //double drlo, drhi;
  dim3 dimBlock, dimGrid;
  //int harm = 0;

  if ( searchRLow[0] < searchRHi[0] ) // This is real data
  {
    nvtxRangePush("Input");

    setStackRVals(batch, searchRLow, searchRHi );

    FOLD  // Normalise and spread and copy to batch memory  .
    {
      if      ( batch->flag & CU_INPT_SINGLE_G  )
      {
        // Copy chunks of FFT data and normalise and spread using the GPU

        if ( batch->noSteps > 1 ) // TODO: multi step
        {
          fprintf(stderr,"ERROR: CU_INPT_SINGLE_G has not been set up for multi-step.");
          exit(EXIT_FAILURE);
        }

        // Make sure the previous thread has complete reading from page locked memory
        CUDA_SAFE_CALL(cudaEventSynchronize(batch->iDataCpyComp), "ERROR: copying data to device");
        nvtxRangePush("Zero");
        memset(batch->h_iData, 0, batch->inpDataSize*batch->noSteps);
        nvtxRangePop();

        FOLD // Copy fft data to device
        {

          for (int step = 0; step < batch->noSteps; step++)
          {
            int harm = 0;
            int sz = 0;

            // Write fft data segments to contiguous page locked memory
            for (int stack = 0; stack< batch->noStacks; stack++)
            {
              cuFfdotStack* cStack = &batch->stacks[stack];

              for (int si = 0; si< cStack->noInStack; si++)
              {
                cuHarmInfo* cHInfo = &batch->hInfos[harm];  // The current harmonic we are working on
                cuFFdot* cPlain = &batch->plains[harm];     //

                rVals* rVal = &((*batch->rInput)[step][harm]);

                /*
                drlo = calc_required_r_gpu(cHInfo->harmFrac, searchRLow[0]);
                drhi = calc_required_r_gpu(cHInfo->harmFrac, searchRHi[0]);

                binoffset = cHInfo->halfWidth;
                lobin = (int) floor(drlo) - binoffset;
                hibin = (int)  ceil(drhi) + binoffset;
                numdata = hibin - lobin + 1;

                numrs = (int) ((ceil(drhi) - floor(drlo)) * ACCEL_RDR + DBLCORRECT) + 1;
                if (harm == 0)
                {
                  //numrs = ACCEL_USELEN;
                  numrs = plains->accelLen;
                }
                else if (numrs % ACCEL_RDR)
                  numrs = (numrs / ACCEL_RDR + 1) * ACCEL_RDR;
                int numtocopy = cHInfo->width - 2 * cHInfo->halfWidth * ACCEL_NUMBETWEEN;
                if (numrs < numtocopy)
                  numtocopy = numrs;
                 */

                lengths.val[harm]       = rVal->numdata;
                d_iDataList.val[harm]   = cPlain->d_iData;
                widths.val[harm]        = cStack->width;

                int start = 0;
                if ( rVal->lobin < 0 )
                  start = -rVal->lobin;

                // Do the actual copy
                memcpy(&batch->h_iData[sz+start], &fft[rVal->lobin+start], (rVal->numdata-start)* sizeof(fcomplexcu));

                sz += cStack->inpStride;

                harm++;
              }
            }

            // Synchronisation
            for (int stack = 0; stack < batch->noStacks; stack++)
            {
              cuFfdotStack* cStack = &batch->stacks[stack];
              CUDA_SAFE_CALL(cudaStreamWaitEvent(batch->inpStream, cStack->convComp, 0), "ERROR: waiting for GPU to be ready to copy data to device\n");
            }

            // Copy to device
            CUDA_SAFE_CALL(cudaMemcpyAsync(batch->d_iData, batch->h_iData, batch->inpDataSize, cudaMemcpyHostToDevice, batch->inpStream), "Failed to copy data to device");

            // Synchronisation
            cudaEventRecord(batch->iDataCpyComp, batch->inpStream);

            CUDA_SAFE_CALL(cudaGetLastError(), "Copying a section of input FTD data to the device.");
          }
        }

        FOLD // Normalise and spread
        {
          // Blocks of 1024 threads ( the maximum number of threads per block )
          dimBlock.x = NAS_DIMX;
          dimBlock.y = NAS_DIMY;
          dimBlock.z = 1;

          // One block per harmonic, thus we can sort input powers in Shared memory
          dimGrid.x = batch->noHarms;
          dimGrid.y = 1;

          // Synchronisation
          CUDA_SAFE_CALL(cudaStreamWaitEvent(batch->inpStream, batch->iDataCpyComp, 0), "ERROR: waiting for GPU to be ready to copy data to device\n");

          // Call the kernel to normalise and spread the input data
          normAndSpreadBlks<<<dimGrid, dimBlock, (lengths.val[0]+1)*sizeof(float), batch->inpStream>>>(d_iDataList, lengths, widths);

          // Synchronisation
          cudaEventRecord(batch->normComp, batch->inpStream);

          CUDA_SAFE_CALL(cudaGetLastError(), "Calling the normalisation and spreading kernel.");
        }
      }
      else if ( batch->flag & CU_INPT_HOST      )
      {
        // Copy chunks of FFT data and normalise and spread using the GPU

        if ( batch->noSteps > 1 ) // TODO: multi step
        {
          fprintf(stderr,"ERROR: CU_INPT_HOST has not been set up for multi-step.");
          exit(EXIT_FAILURE);
        }

        // Make sure the previous thread has complete reading from page locked memory
        CUDA_SAFE_CALL(cudaEventSynchronize(batch->iDataCpyComp), "ERROR: copying data to device");
        //nvtxRangePush("Zero");
        //memset(plains->h_iData, 0, plains->inpDataSize);
        CUDA_SAFE_CALL(cudaMemsetAsync(batch->d_iData, 0, batch->inpDataSize*batch->noSteps, batch->inpStream),"Initialising input data to 0");
        //nvtxRangePop();

        FOLD // Copy fft data to device
        {
          int harm = 0;
          int sz = 0;

          int step = 0; // TODO myltistep

          // Write fft data segments to contiguous page locked memory
          for (int ss = 0; ss< batch->noStacks; ss++)
          {
            cuFfdotStack* cStack = &batch->stacks[ss];

            // Synchronisation
            CUDA_SAFE_CALL(cudaStreamWaitEvent(batch->inpStream, cStack->convComp, 0), "ERROR: waiting for GPU to be ready to copy data to device\n");

            for (int si = 0; si< cStack->noInStack; si++)
            {
              cuHarmInfo* cHInfo  = &batch->hInfos[harm];  // The current harmonic we are working on
              cuFFdot*    cPlain  = &batch->plains[harm];  //
              rVals*      rVal    = &((*batch->rInput)[step][harm]);

/*
              drlo = calc_required_r_gpu(cHInfo->harmFrac, searchRLow[0]);
              drhi = calc_required_r_gpu(cHInfo->harmFrac, searchRHi[0]);

              binoffset = cHInfo->halfWidth;
              lobin     = (int) floor(drlo) - binoffset;
              hibin     = (int)  ceil(drhi) + binoffset;
              numdata   = hibin - lobin + 1;

              numrs     = (int) ((ceil(drhi) - floor(drlo)) * ACCEL_RDR + DBLCORRECT) + 1;
              if (harm == 0)
              {
                numrs = batch->accelLen;
              }
              else if (numrs % ACCEL_RDR)
                numrs = (numrs / ACCEL_RDR + 1) * ACCEL_RDR;
              int numtocopy = cHInfo->width - 2 * cHInfo->halfWidth * ACCEL_NUMBETWEEN;
              if (numrs < numtocopy)
                numtocopy = numrs;
*/

              lengths.val[harm]       = rVal->numdata;
              d_iDataList.val[harm]   = cPlain->d_iData;
              widths.val[harm]        = cStack->width;

              int start = 0;

              if ( (rVal->lobin - batch->SrchSz->rLow)  < 0 )
              {
                // This should be unnecessary as rLow can be < 0 and h_iData is zero padded
                start = -(rVal->lobin - batch->SrchSz->rLow);
                CUDA_SAFE_CALL(cudaMemsetAsync(cPlain->d_iData, 0, start*sizeof(fcomplexcu), batch->inpStream),"Initialising input data to 0");
              }

              // Copy section to device
              CUDA_SAFE_CALL(cudaMemcpyAsync(&cPlain->d_iData[start], &batch->h_iData[rVal->lobin-batch->SrchSz->rLow+start], (rVal->numdata-start)*sizeof(fcomplexcu), cudaMemcpyHostToDevice, batch->inpStream), "Failed to copy data to device");

              sz += cStack->inpStride;

              if ( DBG_INP01 ) // Print debug info
              {
                printf("\nCPU Input Data RAW FFTs [ Half width: %i  lowbin: %i  drlo: %.2f ] \n", cHInfo->halfWidth, rVal->lobin, rVal->drlo);

                printfData<<<1,1,0,batch->inpStream>>>((float*)cPlain->d_iData,10,1, cStack->inpStride);
                CUDA_SAFE_CALL(cudaStreamSynchronize(batch->inpStream),"");
              }

              harm++;
            }
          }

          // Synchronisation
          //cudaEventRecord(plains->iDataCpyComp, batch->inpStream);

          CUDA_SAFE_CALL(cudaGetLastError(), "Copying a section of input FTD data to the device.");
        }

        FOLD // Normalise and spread
        {
          // Blocks of 1024 threads ( the maximum number of threads per block )
          dimBlock.x = NAS_DIMX;
          dimBlock.y = NAS_DIMY;
          dimBlock.z = 1;

          // One block per harmonic, thus we can sort input powers in Shared memory
          dimGrid.x = batch->noHarms;
          dimGrid.y = 1;

          // Call the kernel to normalise and spread the input data
          normAndSpreadBlks<<<dimGrid, dimBlock, (lengths.val[0]+1)*sizeof(float), batch->inpStream>>>(d_iDataList, lengths, widths);

          // Synchronisation
          cudaEventRecord(batch->normComp, batch->inpStream);

          CUDA_SAFE_CALL(cudaGetLastError(), "Calling the normalisation and spreading kernel.");
        }
      }
      else if ( batch->flag & CU_INPT_DEVICE    )
      {
        // Copy chunks of FFT data and normalise and spread using the GPU

        if ( batch->noSteps > 1 ) // TODO: multi step  .
        {
          fprintf(stderr,"ERROR: CU_INPT_DEVICE has not been set up for multi-step.");
          exit(EXIT_FAILURE);
        }

        // Make sure the previous thread has complete reading from page locked memory
        //CUDA_SAFE_CALL(cudaEventSynchronize(plains->iDataCpyComp), "ERROR: copying data to device");
        //nvtxRangePush("Zero");
        //memset(plains->h_iData, 0, plains->inpDataSize);
        //nvtxRangePop();

        FOLD // Setup parameters
        {
          int harm  = 0;
          int step  = 0; // TODO multistep
          int sz    = 0;

          for (int ss = 0; ss< batch->noStacks; ss++)
          {
            cuFfdotStack* cStack = &batch->stacks[ss];

            for (int si = 0; si< cStack->noInStack; si++)
            {
              cuHarmInfo* cHInfo  = &batch->hInfos[harm];  // The current harmonic we are working on
              cuFFdot*    cPlain  = &batch->plains[harm];     //
              rVals*      rVal    = &((*batch->rInput)[step][harm]);

              /*
              drlo = calc_required_r_gpu(cHInfo->harmFrac, searchRLow[0]);
              drhi = calc_required_r_gpu(cHInfo->harmFrac, searchRHi[0]);

              binoffset = cHInfo->halfWidth;
              lobin = (int) floor(drlo) - binoffset;
              hibin = (int)  ceil(drhi) + binoffset;
              numdata = hibin - lobin + 1;

              numrs = (int) ((ceil(drhi) - floor(drlo)) * ACCEL_RDR + DBLCORRECT) + 1;
              if (harm == 0)
              {
                numrs = batch->accelLen;
              }
              else if (numrs % ACCEL_RDR)
                numrs = (numrs / ACCEL_RDR + 1) * ACCEL_RDR;
              int numtocopy = cHInfo->width - 2 * cHInfo->halfWidth * ACCEL_NUMBETWEEN;
              if (numrs < numtocopy)
                numtocopy = numrs;
*/

              lengths.val[harm]     = rVal->numdata;
              d_iDataList.val[harm] = cPlain->d_iData;
              widths.val[harm]      = cStack->width;
              if ( rVal->lobin-batch->SrchSz->rLow < 0 )
              {
                // NOTE could use an offset parameter here
                printf("ERROR: Input data index out of bounds.\n");
                exit(EXIT_FAILURE);
              }
              d_fftList.val[harm]   = &batch->d_iData[rVal->lobin-batch->SrchSz->rLow];

              sz += cStack->inpStride;

              harm++;
            }
          }
        }

        FOLD // Normalise and spread
        {
          // Blocks of 1024 threads ( the maximum number of threads per block )
          dimBlock.x = NAS_DIMX;
          dimBlock.y = NAS_DIMY;
          dimBlock.z = 1;

          // One block per harmonic, thus we can sort input powers in Shared memory
          dimGrid.x = batch->noHarms;
          dimGrid.y = 1;

          // Synchronisation
          for (int ss = 0; ss< batch->noStacks; ss++)
          {
            cuFfdotStack* cStack = &batch->stacks[ss];
            CUDA_SAFE_CALL(cudaStreamWaitEvent(batch->inpStream, cStack->convComp, 0), "ERROR: waiting for GPU to be ready to copy data to device\n");
          }

          // Call the kernel to normalise and spread the input data
          normAndSpreadBlksDevice<<<dimGrid, dimBlock, (lengths.val[0]+1)*sizeof(float), batch->inpStream>>>(d_fftList, d_iDataList, lengths, widths);

          // Synchronisation
          cudaEventRecord(batch->normComp, batch->inpStream);

          CUDA_SAFE_CALL(cudaGetLastError(), "Calling the normalisation and spreading kernel.");
        }
      }
      else if ( batch->flag & CU_INPT_SINGLE_C  )
      {
        // Copy chunks of FFT data and normalise and spread using the CPU

        // Make sure the previous thread has complete reading from page locked memory
        CUDA_SAFE_CALL(cudaEventSynchronize(batch->iDataCpyComp), "ERROR: copying data to device");
        nvtxRangePush("Zero");
        memset(batch->h_iData, 0, batch->inpDataSize*batch->noSteps);
        nvtxRangePop();

        CPU_Norm_Spread(batch, searchRLow, searchRHi, norm_type, fft);

        // Synchronisation
        for (int ss = 0; ss< batch->noStacks; ss++)
        {
          cuFfdotStack* cStack = &batch->stacks[ss];
          CUDA_SAFE_CALL(cudaStreamWaitEvent(batch->inpStream, cStack->convComp, 0), "ERROR: waiting for GPU to be ready to copy data to device\n");
        }

        // Copy to device
        CUDA_SAFE_CALL(cudaMemcpyAsync(batch->d_iData, batch->h_iData, batch->inpDataSize*batch->noSteps, cudaMemcpyHostToDevice, batch->inpStream), "Failed to copy data to device");

        // Synchronisation
        cudaEventRecord(batch->iDataCpyComp, batch->inpStream);
        cudaEventRecord(batch->normComp, batch->inpStream);

        CUDA_SAFE_CALL(cudaGetLastError(), "Error preparing the input data.");
      }
    }

    if ( DBG_INP03 ) // Print debug info  .
    {
      for (int ss = 0; ss< batch->noHarms && true; ss++)
      {
        cuFFdot* cPlain     = &batch->plains[ss];
        printf("\nGPU Input Data pre FFT h:%i   f: %f\n",ss,cPlain->harmInf->harmFrac);
        printfData<<<1,1,0,0>>>((float*)cPlain->d_iData,10,1, cPlain->harmInf->inpStride);
        CUDA_SAFE_CALL(cudaStreamSynchronize(0),"");
        for (int ss = 0; ss< batch->noStacks; ss++)
        {
          cuFfdotStack* cStack = &batch->stacks[ss];
          CUDA_SAFE_CALL(cudaStreamSynchronize(cStack->fftIStream),"");
        }
      }
    }

    FOLD // fft the input data  .
    {
      // I tested doing the FFT's on the CPU and its way to slow! so go GPU!
      // TODO: I could make this a flag

      for (int ss = 0; ss< batch->noStacks; ss++)
      {
        cuFfdotStack* cStack = &batch->stacks[ss];

        // Synchronise
        cudaStreamWaitEvent(cStack->fftIStream, batch->normComp, 0);

        CUDA_SAFE_CALL(cudaGetLastError(), "Error before input fft.");

        // Do the FFT
#pragma omp critical
        {
          CUFFT_SAFE_CALL(cufftSetStream(cStack->inpPlan, cStack->fftIStream),"Failed associating a CUFFT plan with FFT input stream\n");
          CUFFT_SAFE_CALL(cufftExecC2C(cStack->inpPlan, (cufftComplex *) cStack->d_iData, (cufftComplex *) cStack->d_iData, CUFFT_FORWARD),"Failed to execute input CUFFT plan.");

          CUDA_SAFE_CALL(cudaGetLastError(), "Error FFT'ing the input data.");
        }

        // Synchronise
        cudaEventRecord(cStack->prepComp, cStack->fftIStream);
      }

      CUDA_SAFE_CALL(cudaGetLastError(), "Error FFT'ing the input data.");
    }

    if ( DBG_INP04 ) // Print debug info  .
    {
      for (int ss = 0; ss< batch->noHarms && true; ss++)
      {
        cuFFdot* cPlain     = &batch->plains[ss];
        printf("\nGPU Input Data post FFT h:%i   f: %f\n",ss,cPlain->harmInf->harmFrac);
        printfData<<<1,1,0,0>>>((float*)cPlain->d_iData,10,1, cPlain->harmInf->inpStride);
        CUDA_SAFE_CALL(cudaStreamSynchronize(0),"");
        for (int ss = 0; ss< batch->noStacks; ss++)
        {
          cuFfdotStack* cStack = &batch->stacks[ss];
          CUDA_SAFE_CALL(cudaStreamSynchronize(cStack->fftIStream),"");
        }
      }
    }

    batch->haveInput = 1;

    nvtxRangePop();
  }
}

void search_ffdot_planeCU(cuFFdotBatch* plains, double* searchRLow, double* searchRHi, int norm_type, int search, fcomplexcu* fft, long long* numindep, GSList** cands)
{
  CUDA_SAFE_CALL(cudaGetLastError(), "Error entering search_ffdot_planeCU.");

  FOLD // Initialise input data  .
  {
    initInput(plains, searchRLow, searchRHi, norm_type, fft);
  }

  FOLD // Sum & Search  .
  {
    sumAndSearch(plains, numindep, cands);
  }

  FOLD // Convolve & FFT  .
  {
    convolveStack(plains);
  }

  // Set the r-values and width for the next iteration when we will be doing the actual Add and Search
  //setStackRVals(plains, searchRLow, searchRHi);
  cycleRlists(plains);
}

void max_ffdot_planeCU(cuFFdotBatch* plains, double* searchRLow, double* searchRHi, int norm_type, fcomplexcu* fft, long long* numindep, float* powers)
{
  CUDA_SAFE_CALL(cudaGetLastError(), "Error entering ffdot_planeCU2.");

  if ( searchRLow[0] < searchRHi[0] ) // Initialise input data
  {
    initInput(plains, searchRLow, searchRHi, norm_type, fft);
  }

  FOLD // Sum & Search
  {
    //printf("Sum & Search\n");
    sumAndMax(plains, numindep, powers);
  }

  if ( searchRLow[0] < searchRHi[0] ) // Convolve & FFT
  {
    //printf("Convolve & FFT\n");
    convolveStack(plains);
  }

  // Set the r-values and width for the next iteration when we will be doing the actual Add and Search
  //setStackRVals(plains, searchRLow, searchRHi);
  cycleRlists(plains);
}

int selectDevice(int device, int print)
{
  cudaDeviceProp deviceProp;
  int currentDevvice, deviceCount;  //, device = 0;

  CUDA_SAFE_CALL(cudaGetDeviceCount(&deviceCount), "Failed to get device count using cudaGetDeviceCount");
  //printf("There are %i CUDA capable devices available.");
  if (device>= deviceCount)
  {
    if (deviceCount== 0)
    {
      fprintf(stderr, "ERROR: Could not detect any CUDA capable devices!\n");
      exit(EXIT_FAILURE);
    }
    fprintf(stderr, "ERROR: Attempting to select device %i when I detect only %i devices, using device 0 instead!\n", device, deviceCount);
    device = 0;
  }

  CUDA_SAFE_CALL(cudaSetDevice(device), "ERROR: cudaSetDevice");
  CUDA_SAFE_CALL(cudaDeviceReset(), "ERROR: cudaDeviceReset");
  CUDA_SAFE_CALL(cudaGetLastError(), "CUDA Error At start of everything?.\n");
  CUDA_SAFE_CALL(cudaGetDevice(&currentDevvice), "Failed to get device using cudaGetDevice");
  if (currentDevvice!= device)
  {
    fprintf(stderr, "ERROR: CUDA Device not set.\n");
    exit(EXIT_FAILURE);
  }

  CUDA_SAFE_CALL(cudaGetDeviceProperties(&deviceProp, currentDevvice), "Failed to get device properties device using cudaGetDeviceProperties");

  if (print)
    printf("\nRunning on device %d: \"%s\"  which has CUDA Capability  %d.%d\n", device, deviceProp.name, deviceProp.major, deviceProp.minor);

  return ((deviceProp.major<< 4)+ deviceProp.minor);
}

void printCands(const char* fileName, GSList *cands)
{
  if ( cands == NULL  )
    return;

  GSList *tmp_list = cands ;

  FILE * myfile;                    /// The file being written to
  myfile = fopen ( fileName, "w" );

  if ( myfile == NULL )
    fprintf ( stderr, "ERROR: Unable to open log file %s\n", fileName );
  else
  {
    fprintf(myfile, "# ; r ; z ; sig ; power ; harm \n");
    int i = 0;

    while ( tmp_list->next )
    {
      fprintf(myfile, "%i ; %14.5f ; %14.2f ; %-7.4f ; %7.2f ; %i \n", i, ((accelcand *) (tmp_list->data))->r, ((accelcand *) (tmp_list->data))->z, ((accelcand *) (tmp_list->data))->sigma, ((accelcand *) (tmp_list->data))->power, ((accelcand *) (tmp_list->data))->numharm );
      tmp_list = tmp_list->next;
      i++;
    }
    fclose ( myfile );
  }
}

void printContext()
{
  int currentDevvice;
  CUcontext pctx;
  cuCtxGetCurrent ( &pctx );
  CUDA_SAFE_CALL(cudaGetDevice(&currentDevvice), "Failed to get device using cudaGetDevice");

  int trd;
#ifdef WITHOMP
  trd = omp_get_thread_num();
#else
  trd = 0;
#endif

  printf("Thread %02i  currentDevvice: %i Context %p \n", trd, currentDevvice, pctx);
}

void setContext(cuFFdotBatch* stkList)
{
  int dev;
  //printf("Setting device to %i \n", stkList->device);
  CUDA_SAFE_CALL(cudaSetDevice(stkList->device), "ERROR: cudaSetDevice");
  CUDA_SAFE_CALL(cudaGetDevice(&dev), "Failed to get device using cudaGetDevice");
  if ( dev != stkList->device )
  {
    fprintf(stderr, "ERROR: CUDA Device not set.\n");
    exit(EXIT_FAILURE);
  }

  /*
  CUcontext pctx;
  cuCtxGetCurrent ( &pctx );
  if(pctx !=  stkList->pctx )
  {
    CUresult res = cuCtxSetCurrent(stkList->pctx);
  }
   */

  //CUcontext pctx;
  //cuCtxGetCurrent ( &pctx );
  //printf("Thread %02i  Context %p \n", omp_get_thread_num(), pctx);
}

void testzm()
{
  cufftHandle plan;
  CUFFT_SAFE_CALL(cufftCreate(&plan),"Failed associating a CUFFT plan with FFT input stream\n");
}

gpuSpecs gSpec(int devID = -1 )
{
  gpuSpecs gSpec;
  memset(&gSpec, 0 , sizeof(gpuSpecs));

  if (devID < 0 )
  {
    gSpec.noDevices      = getGPUCount();
    for ( int i = 0; i < gSpec.noDevices; i++)
      gSpec.devId[i]        = i;
  }
  else
  {
    gSpec.noDevices      = 1;
    gSpec.devId[0]       = devID;
  }

  // Set default
  for ( int i = 0; i < gSpec.noDevices; i++)
  {
    gSpec.noDevBatches[i] = 2;
    gSpec.noDevSteps[i]   = 4;
  }
  return gSpec;
}

/*
cuMemInfo* newcuMemInfo( int noDevs = 1 )
{
  cuMemInfo* bInf    = new cuMemInfo;
  memset(bInf, 0 , sizeof(cuMemInfo));

  bInf->noDevices      = noDevs;
  bInf->devId          = new int[noDevs];
  bInf->noDevBatches   = new int[noDevs];
  bInf->noDevSteps     = new int[noDevs];

  // Set default
  for ( int i = 0; i < noDevs; i++)
  {
    bInf->devId[i]        = i;
    bInf->noDevBatches[i] = 2;
    bInf->noDevSteps[i]   = 4;
  }

  return bInf;
}
*/

/*
cuMemInfo* oneDevice(int dev, fftInfo* fftinf, int numharmstages=3, int zMax=200, int width=8, int noBatches = 2, int noSteps = 4, int flags = 0, int candType = CU_FULLCAND, int retType = CU_SMALCAND, void* out = NULL)
{
  long long numindep[numharmstages];
  float powcut[numharmstages];
  int numz = zMax*ACCEL_DZ+1;
  cuMemInfo* bInf;

  bInf->devId[0]          = dev;
  bInf->noDevBatches[0]   = noBatches;
  bInf->noDevSteps[0]     = noSteps;

  if(dev< 0)
    bInf       = newcuMemInfo(getGPUCount());
  else
    bInf       = newcuMemInfo(1);

  for (int ii = 0; ii < numharmstages; ii++)
  {
    if (zMax == 1)
      numindep[ii] = (fftinf->rhi - fftinf->rlo) / (1<<ii);
    else
    {
      numindep[ii]  = (fftinf->rhi - fftinf->rlo) * (numz + 1) * (ACCEL_DZ / 6.95) / (1<<ii);
      powcut[ii]    = power_for_sigma(2, (1<<ii), numindep[ii]);
    }
  }

  initCuAccel(bInf, fftinf, numharmstages, zMax, width, powcut, numindep, flags, candType, retType, out);

  return bInf;
}
*/

/**  Read the GPU details from clig command line
 *
 * @param cmd     clig struct
 * @param bInf    A pointer to the accel info struct to fill
 */
gpuSpecs readGPUcmd(Cmdline *cmd)
{
  gpuSpecs gpul;

  if ( cmd->gpuP ) // Determine the index and number of devices
  {
    if ( cmd->gpuC == 0 )  // NB: Note using gpuC == 0 requires a change in accelsearch_cmd every time clig is run!!!!
    {
      // Make a list of all devices
      gpul.noDevices   = getGPUCount();
      for ( int dev = 0 ; dev < gpul.noDevices; dev++ )
        gpul.devId[dev] = dev;
    }
    else
    {
      gpul.noDevices   = cmd->gpuC;
      for ( int dev = 0 ; dev < gpul.noDevices; dev++ )
        gpul.devId[dev] = cmd->gpu[dev];
    }
  }

  for ( int dev = 0 ; dev < gpul.noDevices; dev++ ) // Loop over devices  .
  {
    if ( dev >= cmd->nbatchC )
      gpul.noDevBatches[dev] = cmd->nbatch[cmd->nbatchC-1];
    else
      gpul.noDevBatches[dev] = cmd->nbatch[dev];

    if ( dev >= cmd->nstepsC )
      gpul.noDevSteps[dev] = cmd->nsteps[cmd->nbatchC-1];
    else
      gpul.noDevSteps[dev] = cmd->nsteps[dev];
  }

  return gpul;
}

searchSpecs readSrchSpecs(Cmdline *cmd, accelobs* obs)
{
  searchSpecs sSpec;
  memset(&sSpec, 0, sizeof(sSpec));

  // Defaults for accel search
  sSpec.flags         |= FLAG_RETURN_ALL ;
  sSpec.flags         |= CU_CAND_ARR ;
  sSpec.flags         |= FLAG_STP_ROW ;  //   FLAG_STP_ROW    FLAG_STP_PLN
  sSpec.flags         |= FLAG_PLN_TEX ;
  sSpec.flags         |= FLAG_CUFFTCB_OUT ;

  sSpec.outType       = CU_FULLCAND ;

  sSpec.fftInf.fft    = obs->fft;
  sSpec.fftInf.nor    = obs->N;
  sSpec.fftInf.rlo    = obs->rlo;
  sSpec.fftInf.rhi    = obs->rhi;

  sSpec.noHarmStages  = obs->numharmstages;
  sSpec.zMax          = obs->zhi;
  sSpec.sigma         = cmd->sigma;
  sSpec.pWidth        = cmd->width;

  return sSpec;
}

/*
cuMemInfo* initCuAccel(cuSearch* srch)
{
  srch->mInf = new cuMesrch->mInfo;
  memset(srch->mInf, 0, sizeof(cuMesrch->mInfo));

  srch->mInf->noBatches = 0;

  srch->gSpec

  FOLD // Create a kernel on each device
  {
    nvtxRangePush("Init Kernels");

    srch->mInf->kernels = (cuFFdotBatch*)malloc(srch->gSpec->noDevices*sizeof(cuFFdotBatch));

    int added;
    cuFFdotBatch* master = NULL;

    for ( int dev = 0 ; dev < srch->mInf->noDevices; dev++ ) // Loop over devices  .
    {
      added = initHarmonics(&srch->mInf->kernels[dev], master, srch->noHarmStages, srch->sSpec->zMax, srch->sSpec->fftInf, srch->gSpec->devId[dev], srch->gSpec->noDevBatches[dev], srch->gSpec->noDevSteps[dev], srch->sSpec->pWidth, srch->powerCut, srch->numindep, srch->sSpec->flags, srch->sSpec->outType, retType, srch->sSpec->outData );

      if ( added && (master == NULL) )
      {
        master = &srch->mInf->kernels[0];
      }
      srch->mInf->noDevBatches[dev] = added;

      if ( added )
      {
        aInf->noBatches += added;
      }
      else
      {
        printf("Error: failed to set up a kernel on device %i, trying to continue... \n", srch->mInf->devId[dev]);
      }
    }

    nvtxRangePop();
  }

  FOLD // Create plains for calculations
  {
    nvtxRangePush("Init Batches");

    srch->mInf->noSteps = 0;

    srch->mInf->batches = (cuFFdotBatch**)malloc(srch->mInf->noBatches*sizeof(cuFFdotBatch*));

    int bNo = 0;

    for ( int dev = 0 ; dev < srch->mInf->noDevices; dev++ ) // Loop over devices  .
    {
      for ( int batch = 0 ; batch < srch->mInf->noDevBatches[dev]; batch++ )
      {
        srch->mInf->batches[bNo] = initBatch(&srch->mInf->kernels[dev], batch, srch->mInf->noDevBatches[dev]-1);

        if ( srch->mInf->batches[bNo] == NULL)
        {
          if ( batch == 0 )
          {
            fprintf(stderr, "ERROR: Failed to create at least one batch on device %i.\n", srch->mInf->kernels[dev].device);
          }
          break;
        }
        else
        {
          srch->mInf->noSteps += srch->mInf->batches[bNo]->noSteps;
          bNo++;
        }
      }
    }

    nvtxRangePop();
  }

  return srch->mInf;
}
*/

cuMemInfo* initCuAccel(gpuSpecs* gSpec, searchSpecs*  sSpec, float* powcut, long long* numindep)
{
  cuMemInfo* aInf = new cuMemInfo;
  memset(aInf, 0, sizeof(cuMemInfo));

  aInf->noBatches = 0;

  FOLD // Create a kernel on each device
  {
    nvtxRangePush("Init Kernels");

    aInf->kernels = (cuFFdotBatch*)malloc(gSpec->noDevices*sizeof(cuFFdotBatch));

    int added;
    cuFFdotBatch* master = NULL;

    for ( int dev = 0 ; dev < gSpec->noDevices; dev++ ) // Loop over devices  .
    {
      added = initHarmonics(&aInf->kernels[aInf->noDevices], master, sSpec->noHarmStages, sSpec->zMax, &sSpec->fftInf, gSpec->devId[dev], gSpec->noDevBatches[dev], gSpec->noDevSteps[dev], sSpec->pWidth, powcut, numindep, sSpec->flags, sSpec->outType, sSpec->outData );

      if ( added && !master )
      {
        master = &aInf->kernels[0];
      }

      if ( added )
      {
        aInf->noBatches += added;
        aInf->noDevices++;
      }
      else
      {
        gSpec->noDevBatches[dev] = 0;
        fprintf(stderr, "ERROR: failed to set up a kernel on device %i, trying to continue... \n", gSpec->devId[dev]);
      }
    }

    nvtxRangePop();
  }

  FOLD // Create plains for calculations
  {
    nvtxRangePush("Init Batches");

    aInf->noSteps = 0;

    aInf->batches = (cuFFdotBatch*)malloc(aInf->noBatches*sizeof(cuFFdotBatch));

    int bNo = 0;
    int ker = 0;


    for ( int dev = 0 ; dev < gSpec->noDevices; dev++ ) // Loop over devices  .
    {
      int noSteps = 0;
      if ( gSpec->noDevBatches[dev] > 0 )
      {
        for ( int batch = 0 ; batch < gSpec->noDevBatches[dev]; batch++ )
        {
          noSteps = initBatch(&aInf->batches[bNo], &aInf->kernels[ker], batch, gSpec->noDevBatches[dev]-1);

          if ( noSteps == 0 )
          {
            if ( batch == 0 )
            {
              fprintf(stderr, "ERROR: Failed to create at least one batch on device %i.\n", aInf->kernels[dev].device);
            }
            break;
          }
          else
          {
            aInf->noSteps += noSteps;
            bNo++;
          }
        }
        ker++;
      }
    }

    nvtxRangePop();
  }

  return aInf;
}

cuSearch* initCuSearch(searchSpecs* sSpec, gpuSpecs* gSpec, cuSearch* srch)
{
  bool same   = true;

  if( srch )
  {
    if ( srch->noHarmStages != sSpec->noHarmStages )
    {
      same = false;
      // ERROR recreate everything
    }

    if ( srch->mInf )
    {
      if ( srch->mInf->kernels->hInfos->zmax != sSpec->zMax )
      {
        same = false;
        // Have to recreate
      }
      if ( srch->mInf->kernels->accelLen != optAccellen(sSpec->pWidth,sSpec->zMax) )
      {
        same = false;
        // Have to recreate
      }

      if ( !same )
      {
        fprintf(stderr,"ERROR: Call to %s with differing GPU search paramiters. Will have to allocate new GPU memory and kernels.\n      NB: Not freeing the old memory!", __FUNCTION__);
      }
      else
      {
        // NB Assuming the GPU specks are all the same
      }
    }
  }

  if ( !srch || same == false)
  {
    srch = new cuSearch;
    memset(srch, 0, sizeof(cuSearch));

    srch->noHarmStages  = sSpec->noHarmStages;
    srch->noHarms       = ( 1<<(srch->noHarmStages-1) );

    srch->pIdx          = (int*)malloc(srch->noHarms * sizeof(int));
    srch->powerCut      = (float*)malloc(srch->noHarmStages * sizeof(float));
    srch->numindep      = (long long*)malloc(srch->noHarmStages * sizeof(long long));
  }

  srch->sSpec         = sSpec;
  srch->gSpec         = gSpec;

  FOLD // Calculate power cutoff and number of independent values
  {
    if (sSpec->zMax % ACCEL_DZ)
      sSpec->zMax = (sSpec->zMax / ACCEL_DZ + 1) * ACCEL_DZ;
    int numz = (sSpec->zMax / ACCEL_DZ) * 2 + 1;
    for (int ii = 0; ii < srch->noHarmStages; ii++)
    {
      if (sSpec->zMax == 1)
        srch->numindep[ii] = (sSpec->fftInf.rhi - sSpec->fftInf.rlo) / srch->noHarms;
      else
      {
        srch->numindep[ii]  = (sSpec->fftInf.rhi - sSpec->fftInf.rlo) * (numz + 1) * (ACCEL_DZ / 6.95) / srch->noHarms;
        srch->powerCut[ii]  = power_for_sigma(sSpec->sigma, srch->noHarms, srch->numindep[ii]);
      }
    }
  }

  if ( !srch->mInf )
  {
    srch->mInf = initCuAccel(gSpec, sSpec, srch->powerCut, srch->numindep );
  }
  else
  {
    // TODO do a whole bunch of checks here!
  }

  return srch;
}

int freeCuAccel(cuMemInfo* aInf)
{
  FOLD // Free plains
  {
    for ( int batch = 0 ; batch < aInf->noBatches; batch++ )  // Batches
    {
      freeBatch(&aInf->batches[batch]);
    }
  }

  FOLD // Free kernels
  {
    for ( int dev = 0 ; dev < aInf->noDevices; dev++)  // Loop over devices
    {
      freeHarmonics(&aInf->kernels[dev], &aInf->kernels[0] );
    }
  }

  free(aInf->batches);
  aInf->batches = NULL;
  free(aInf->kernels);
  aInf->kernels = NULL;
}

void accelMax(cuSearch* srch)
{
  /*
  bool newKer = false;


  if ( aInf == NULL )
  {
    newKer = true;
    aInf = oneDevice(-1, fftinf, numharmstages, zMax, 8, 2, 4, CU_CAND_ARR | FLAG_STORE_EXP, CU_FLOAT, CU_FLOAT, (void*)powers );
  }

  master = &srch->mInf->kernels[0];
*/

  cuFFdotBatch* master   = NULL;    // The first kernel stack created
  master = srch->mInf->kernels;

#ifdef WITHOMP
  omp_set_num_threads(srch->mInf->noBatches);
#endif

  int ss = 0;
  int maxxx = ( srch->sSpec->fftInf.rhi - srch->sSpec->fftInf.rlo ) / (float)( master->accelLen * ACCEL_DR ) ; /// The number of plains we can work with

  if ( maxxx < 0 )
    maxxx = 0;

  int firstStep = 0;

#ifndef DEBUG
  #pragma omp parallel
#endif
  FOLD
  {
#ifdef WITHOMP
    int tid = omp_get_thread_num();
#else
    int tid = 0;
#endif

    cuFFdotBatch* trdBatch = &srch->mInf->batches[tid];

    double*  startrs = (double*)malloc(sizeof(double)*trdBatch->noSteps);
    double*  lastrs  = (double*)malloc(sizeof(double)*trdBatch->noSteps);
    size_t rest = trdBatch->noSteps;

    setContext(trdBatch) ;

    while ( ss < maxxx )
    {
#pragma omp critical
      {
        firstStep = ss;
        ss       += trdBatch->noSteps;
        printf("\r   Step %07i of %-i %7.2f%%      \r", firstStep, maxxx,  firstStep/(float)maxxx*100);
        std::cout.flush();
      }

      if ( firstStep >= maxxx )
      {
        break;
      }

      for ( int step = 0; step < trdBatch->noSteps ; step ++)
      {
        if ( step < rest )
        {
          startrs[step] = srch->sSpec->fftInf.rlo   + (firstStep+step) * ( master->accelLen * ACCEL_DR );
          lastrs[step]  = startrs[step] + master->accelLen * ACCEL_DR - ACCEL_DR;
        }
        else
        {
          startrs[step] = 0 ;
          lastrs[step]  = 0 ;
        }
      }
      //max_ffdot_planeCU(trdBatch, startrs, lastrs, 1, (fcomplexcu*)fftinf->fft, numindep, powers );
    }

    for ( int step = 0; step < trdBatch->noSteps ; step ++)
    {
      startrs[step] = 0;
      lastrs[step]  = 0;
    }

    // Finish searching the plains, this is required because of the out of order asynchronous calls
    for ( int pln = 0 ; pln < 2; pln++ )
    {
      //max_ffdot_planeCU(trdBatch, startrs, lastrs, 1,(fcomplexcu*)fftinf->fft, numindep, powers );

      //trdBatch->mxSteps = rest;
    }
    printf("\n");
  }

  /*
  printf("Free plains \n");

  FOLD // Free plains
  {
    for ( int pln = 0 ; pln < nPlains; pln++ )  // Batches
    {
      freeBatch(plainsj[pln]);
    }
  }

  printf("Free kernels \n");

  FOLD // Free kernels
  {
    for ( int dev = 0 ; dev < noKers; dev++)  // Loop over devices
    {
      freeHarmonics(&kernels[dev], master, (void*)powers );
    }
  }
  */

#ifndef DEBUG
  //printCands("GPU_Cands.csv", candsGPU);
#endif
}

void plotPlains(cuFFdotBatch* plains)
{
#ifdef CBL
  printf("\n Creating data sets...\n");

  nDarray<2, float>gpuCmplx [plains->noSteps][plains->noHarms];
  nDarray<2, float>gpuPowers[plains->noSteps][plains->noHarms];
  for ( int si = 0; si < plains->noSteps ; si ++)
  {
    for (int harm = 0; harm < plains->noHarms; harm++)
    {
      cuHarmInfo *hinf  = &plains[0].hInfos[harm];

      gpuCmplx[si][harm].addDim(hinf->width*2, 0, hinf->width);
      gpuCmplx[si][harm].addDim(hinf->height, -hinf->zmax, hinf->zmax);
      gpuCmplx[si][harm].allocate();

      gpuPowers[si][harm].addDim(hinf->width, 0, hinf->width);
      gpuPowers[si][harm].addDim(hinf->height, -hinf->zmax, hinf->zmax);
      gpuPowers[si][harm].allocate();
    }
  }

  for ( int step = 0; step < plains->noSteps ; step ++)
  {
    for ( int stack = 0 ; stack < plains->noStacks; stack++ )
    {
      for (int harm = 0; harm < plains->noHarms; harm++)
      {
        cuHarmInfo   *cHInfo  = &plains->hInfos[harm];
        cuFfdotStack *cStack  = &plains->stacks[cHInfo->stackNo];
        cuFFdot*      cPlain  = &plains->plains[harm];
        rVals*        rVal    = &((*plains->rInput)[step][harm]);

        for( int y = 0; y < cHInfo->height; y++ )
        {

          fcomplexcu *cmplxData;
          float *powers;

          if ( plains->flag & FLAG_STP_ROW )
          {
            cmplxData = &plains->d_plainData[(y*plains->noSteps + step)*cStack->inpStride ];
            powers    = &plains->d_plainPowers[((y*plains->noSteps + step)*cStack->pwrStride + cHInfo->halfWidth * 2 ) ];
          }
          else if ( plains->flag & FLAG_STP_PLN )
          {
            cmplxData = &plains->d_plainData[   (y + step*cHInfo->height)*cStack->inpStride ];
            powers    = &plains->d_plainPowers[((y + step*cHInfo->height)*cStack->pwrStride  + cHInfo->halfWidth * 2 ) ];
          }

          cmplxData += cHInfo->halfWidth*2;
          //CUDA_SAFE_CALL(cudaMemcpyAsync(gpuCmplx[step][harm].getP(0,y), cmplxData, (cHInfo->width-2*2*cHInfo->halfWidth)*2*sizeof(float), cudaMemcpyDeviceToHost, cStack->fftPStream), "Failed to copy input data from device.");
          //CUDA_SAFE_CALL(cudaMemcpyAsync(gpuCmplx[step][harm].getP(0,y), cmplxData, (cPlain->numrs[step])*2*sizeof(float), cudaMemcpyDeviceToHost, cStack->fftPStream), "Failed to copy input data from device.");
          CUDA_SAFE_CALL(cudaMemcpyAsync(gpuCmplx[step][harm].getP(0,y), cmplxData, (rVal->numrs)*2*sizeof(float), cudaMemcpyDeviceToHost, cStack->fftPStream), "Failed to copy input data from device.");
          if ( plains->flag & FLAG_CUFFTCB_OUT )
          {
            //CUDA_SAFE_CALL(cudaMemcpyAsync(gpuPowers[step][harm].getP(0,y), powers, (cPlain->numrs[step])*sizeof(float),   cudaMemcpyDeviceToHost, cStack->fftPStream), "Failed to copy input data from device.");
            CUDA_SAFE_CALL(cudaMemcpyAsync(gpuPowers[step][harm].getP(0,y), powers, (rVal->numrs)*sizeof(float),   cudaMemcpyDeviceToHost, cStack->fftPStream), "Failed to copy input data from device.");
            /*
      for( int jj = 0; jj < plan->numrs[step]; jj++)
      {
        float *add = gpuPowers[step][harm].getP(jj*2+1,y);
        gpuPowers[step][harm].setPoint<ARRAY_SET>(add, 0);
      }
             */
          }
        }
      }
    }
  }
#else
  fprintf(stderr,"ERROR: Not compiled with debug libraries.\n");
#endif
}

/* Return x such that 2**x = n */
//static
inline int twon_to_index(int n)
{
  int x = 0;

  while (n > 1) {
    n >>= 1;
    x++;
  }
  return x;
}

/*
void generatePlain(fftInfo fft, long long loBin, long long hiBin, int zMax, int noHarms)
{
  int width = hiBin - loBin;
  int gpuC = 0;
  int dev  = 0;
  int nplainsC = 5;
  int nplains[10];
  int nsteps[10];
  int gpu[10];
  nplains[0]=2;
  nsteps[0]=2;
  int numharmstages = twon_to_index(noHarms);
  noHarms = 1 << numharmstages ;
  long long numindep[numharmstages];
  float powc[numharmstages];

  int flags;

  gpu[0] = 1;

  cuFFdotBatch* kernels;             // List of stacks with the kernels, one for each device being used
  cuFFdotBatch* master   = NULL;     // The first kernel stack created
  int nPlains           = 0;        // The number of plains
  int noKers            = 0;        // Real number of kernels/devices being used

  fftInfo fftinf;
  fftinf.fft    = fft;
  fftinf.nor    = centerBin + width*2;
  fftinf.rlow   = centerBin - width;
  fftinf.rhi    = centerBin + width;

  int ww =  twon_to_index(width);

  int numz      = (zMax / ACCEL_DZ) * 2 + 1;

  for (int ii = 0; ii < numharmstages; ii++) // Calculate numindep
  {
    powc[ii] = 0;

    if (numz == 1)
      numindep[ii] = (fftinf.rhi - fftinf.rlow) / (1<<ii);
    else
    {
      numindep[ii] = (fftinf.rhi - fftinf.rlow) * (numz + 1) * (ACCEL_DZ / 6.95) / (1<<ii);
    }
  }

  flags = FLAG_CUFFTCB_OUT ;

  gpu[0] = 0;
  kernels = new cuFFdotBatch;
  int added = initHarmonics(kernels, master, numharmstages, zMax, fftinf, 0, 1, ww, 1, powc, numindep, flags, CU_FLOAT, CU_FLOAT, NULL );
  cuFFdotBatch* stkLst = initStkList(kernels, 0, 0);

  cuFFdotBatch* trdStack = stkLst;
  double*  startrs = (double*)malloc(sizeof(double)*trdStack->noSteps);
  double*  lastrs  = (double*)malloc(sizeof(double)*trdStack->noSteps);

  startrs[0] = (centerBin - width) * noHarms ;
  lastrs[0] = startrs[0] + master->accelLen * ACCEL_DR - ACCEL_DR;

  max_ffdot_planeCU(trdStack, startrs, lastrs, 1, (fcomplexcu*)fftinf.fft, numindep, NULL);

  nvtxRangePop();
}
 */

