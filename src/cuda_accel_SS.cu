/** @file cuda_accel_SS.cu
 *  @brief Functions to manage the harmonic summing and searching of ff plane components of an acceleration search
 *
 *  This contains the control of harmonic summing and searching of ff plane components of an acceleration search.
 *  These include the storage of the initial candidates found.
 *
 *  @author Chris Laidler
 *  @bug No known bugs.
 *
 *  Change Log
 *
 *  [0.0.01] []
 *    Beginning of change log
 *    Working version un-numbed
 *
 *  [0.0.02] [2017-02-03]
 *    Converted candidate processing to use a circular buffer of results in pinned memory
 *
 *  [0.0.03] [2017-02-05]
 *    Reorder in-mem async to slightly faster (3 way)
 *
 *  [0.0.03] [2017-02-10]
 *    Multi batch synch fixed finishing off search
 *
 *  [0.0.03] [2017-02-12]
 *    Added the opt out on the count of candidates found
 *    Added the use of FLAG_SS_MEM
 *
 *  [0.0.03] [2017-02-16]
 *    Separated candidate and optimisation CPU threading
 *
 *  [2017-03-30]
 *  	Reworked the way the main in-mem search loop iterates (bounds)
 *  	Added separate candidate array resolution
 *
 *  [2017-03-24]
 *  	Refactor of Y-Indices calculations
 *
 *  [2017-05-12]
 *  	Main Loop bounds using newly refactored bounds
 */

#include "cuda_accel_SS.h"

#include <semaphore.h>

#include <cufft.h>
#include <algorithm>

#include <thrust/sort.h>
#include <thrust/device_vector.h>


#include "cuda_accel.h"
#include "cuda_utils.h"
#include "cuda_accel_utils.h"
#include "cuda_accel_SS.h"
#include "candTree.h"

//======================================= Constant memory =================================================\\

__device__ __constant__ int       YINDS[MAX_YINDS];                   ///< The harmonic related Y index for each plane
__device__ __constant__ float     POWERCUT_STAGE[MAX_HARM_NO];        ///<
__device__ __constant__ float     NUMINDEP_STAGE[MAX_HARM_NO];        ///<

__device__ __constant__ int       HEIGHT_STAGE[MAX_HARM_NO];          ///< Plane heights in stage order
__device__ __constant__ int       STRIDE_STAGE[MAX_HARM_NO];          ///< Plane strides in stage order
__device__ __constant__ int       PSTART_STAGE[MAX_HARM_NO];          ///< Start offset of good points in a plane, stage order

__device__ __constant__ void*     PLN_START;                          ///< A pointer to the start of the in-mem plane
__device__ __constant__ uint      PLN_STRIDE;                         ///< The strided in units of the in-mem plane
__device__ __constant__ int       NO_STEPS;                           ///< The number of steps used in the search  -  NB: this is specific to the batch not the search, but its only used in the inmem search!
__device__ __constant__ int       ALEN;                               ///< CUDA copy of the accelLen used in the search

//====================================== Constant variables  ===============================================\\

__device__ const float FRAC_STAGE[16]     =  { 1.0000f, 0.5000f, 0.7500f, 0.2500f, 0.8750f, 0.6250f, 0.3750f, 0.1250f, 0.9375f, 0.8125f, 0.6875f, 0.5625f, 0.4375f, 0.3125f, 0.1875f, 0.0625f } ;
__device__ const float STP_STAGE[16]      =  { 32, 16, 24, 8, 28, 20, 12, 4, 30, 26, 22, 18, 14, 10, 6, 2 } ;

//__device__ const float FRAC_STAGE[16]     =  { 1.0000f, 0.5000f, 0.2500f, 0.7500f, 0.1250f, 0.3750f, 0.6250f, 0.8750f, 0.0625f, 0.1875f, 0.3125f, 0.4375f, 0.5625f, 0.6875f, 0.8125f, 0.9375f } ;

__device__ const float FRAC_HARM[16]      =  { 1.0f, 0.9375f, 0.875f, 0.8125f, 0.75f, 0.6875f, 0.625f, 0.5625f, 0.5f, 0.4375f, 0.375f, 0.3125f, 0.25f, 0.1875f, 0.125f, 0.0625f } ;
__device__ const short STAGE[5][2]        =  { {0,0}, {1,1}, {2,3}, {4,7}, {8,15} } ;
__device__ const short NO_HARMS[5]        =  { 1, 1, 2, 4, 8 } ;


//======================================= Global variables  ================================================\\


//========================================== Functions  ====================================================\\

/** Return x such that 2**x = n
 *
 * @param n
 * @return
 */
__host__ __device__ inline int twon_to_index(int n)
{
  int x = 0;

  while (n > 1)
  {
    n >>= 1;
    x++;
  }
  return x;
}

template<int64_t FLAGS>
__device__ inline int getY(int planeY, const int noSteps,  const int step, const int planeHeight = 0 )
{
  // Calculate y indice from interleave method
#ifdef WITH_ITLV_PLN
  if      ( FLAGS & FLAG_ITLV_ROW )
  {
    return planeY * noSteps + step;
  }
  else
  {
    return planeY + planeHeight*step;
  }
#endif

  // Row-interleaved by default
  return planeY * noSteps + step;
}

/** Main loop down call
 *
 * This will asses and call the correct templated kernel
 *
 * @param dimGrid
 * @param dimBlock
 * @param stream
 * @param batch
 */
__host__ void add_and_searchCU3(cudaStream_t stream, cuFFdotBatch* batch )
{
  const int64_t FLAGS = batch->flags ;

  if      ( FLAGS & FLAG_SS_00 )
  {
    add_and_searchCU00(stream, batch );
  }
  else if ( FLAGS & FLAG_SS_31 )
  {
    add_and_searchCU31(stream, batch );
  }
  //  else if ( FLAGS & FLAG_SS_32 )
  //  {
  //    add_and_searchCU32(stream, batch );
  //  }
  //		Deprecated
  //
  //    else if ( FLAGS & FLAG_SS_30 )
  //    {
  //      add_and_searchCU33(stream, batch );
  //    }
  else
  {
    fprintf(stderr,"ERROR: Invalid sum and search kernel.\n");
    exit(EXIT_FAILURE);
  }
}

/**
 *  This needs to be here because the constant variables are here
 */
int setConstVals( cuFFdotBatch* batch )
{
  void *dcoeffs;

  int numharmstages	= batch->cuSrch->noHarmStages;
  float *powcut		= batch->cuSrch->powerCut;
  long long *numindep	= batch->cuSrch->numindep;

  FOLD // Calculate Y coefficients and copy to constant memory  .
  {
    int noHarms         = batch->cuSrch->noSrchHarms;

    if ( ((batch->hInfos->noZ + INDS_BUFF) * noHarms) > MAX_YINDS)
    {
      printf("ERROR! YINDS to small!");
    }

    freeNull(batch->cuSrch->yInds);
    batch->cuSrch->yInds  = (int*) malloc( (batch->hInfos->noZ + INDS_BUFF) * noHarms * sizeof(int));
    int *indsY            = batch->cuSrch->yInds;
    int bace              = 0;

    batch->hInfos->yInds  = 0;

    for (int ii = 0; ii < noHarms; ii++)
    {
      double sZstart, harmFrac;
      int noZ, dir, sIdx;
      cuHarmInfo* hInf;
      cuHarmInfo* fInf;

      fInf		= batch->hInfos;
      sIdx		= batch->cuSrch->sIdx[ii];
      hInf		= &batch->hInfos[sIdx];
      dir		= (hInf->zEnd > hInf->zStart?1:-1);
      harmFrac		= hInf->harmFrac;

      if ( batch->flags & FLAG_SS_INMEM )
      {
	// Only the fundamental in the full plane so use single start
	sZstart		= fInf->zStart;
	noZ		= fInf->noZ;
      }
      else
      {
	sZstart		= hInf->zStart;
	noZ		= hInf->noZ;
      }

      for ( int j = 0; j < fInf->noZ; j++ )	// Loop over rows of the fundamental  .
      {
	double fundZ	= fInf->zStart + j * dir * batch->conf->zRes;
	double subzf	= cu_calc_required_z<double>( harmFrac, fundZ, batch->conf->zRes );
	int zind	= cu_index_from_z<double>( subzf, sZstart, batch->conf->zRes );

	MAXX(zind, 0);
	MINN(zind, noZ-1);

	indsY[bace + j] = zind;
      }

      // Set the yindex value in the harmonic info for CPU sum and search
      if ( ii < batch->noSrchHarms )
      {
	hInf->yInds	= bace;
      }

      bace += fInf->noZ;

      // Buffer with last lookup index
      for (int j = 0; j < INDS_BUFF; j++)
      {
	indsY[bace + j] = indsY[bace + j-1];
      }

      bace += INDS_BUFF;
    }

    cudaGetSymbolAddress((void **)&dcoeffs, YINDS);
    CUDA_SAFE_CALL(cudaMemcpyAsync(dcoeffs, indsY, bace*sizeof(int), cudaMemcpyHostToDevice, batch->stacks->initStream),                      "Copying Y indices to device");
  }

  FOLD // copy power cutoff values  .
  {
    if ( powcut )
    {
      cudaGetSymbolAddress((void **)&dcoeffs, POWERCUT_STAGE);
      CUDA_SAFE_CALL(cudaMemcpyAsync(dcoeffs, powcut, numharmstages * sizeof(float), cudaMemcpyHostToDevice, batch->stacks->initStream),      "Copying power cutoff to device");
    }
    else
    {
      float pw[5];
      for ( int i = 0; i < 5; i++)
      {
	pw[i] = 0;
      }
      cudaGetSymbolAddress((void **)&dcoeffs, POWERCUT_STAGE);
      CUDA_SAFE_CALL(cudaMemcpyAsync(dcoeffs, &pw, 5 * sizeof(float), cudaMemcpyHostToDevice, batch->stacks->initStream),         "Copying power cutoff to device");
    }
  }

  FOLD // number of independent values  .
  {
    if (numindep)
    {
      cudaGetSymbolAddress((void **)&dcoeffs, NUMINDEP_STAGE);
      CUDA_SAFE_CALL(cudaMemcpyAsync(dcoeffs, numindep, numharmstages * sizeof(long long), cudaMemcpyHostToDevice, batch->stacks->initStream),  "Copying stages to device");
    }
    else
    {
      long long numi[5];
      for ( int i = 0; i < 5; i++)
      {
	numi[i] = 0;
      }
      cudaGetSymbolAddress((void **)&dcoeffs, NUMINDEP_STAGE);
      CUDA_SAFE_CALL(cudaMemcpyAsync(dcoeffs, &numi, 5 * sizeof(long long), cudaMemcpyHostToDevice, batch->stacks->initStream),      "Copying stages to device");

    }
  }

  FOLD // Some other values  .
  {
    cudaGetSymbolAddress((void **)&dcoeffs, NO_STEPS);
    CUDA_SAFE_CALL(cudaMemcpyAsync(dcoeffs,  &(batch->noSteps),  sizeof(int), cudaMemcpyHostToDevice, batch->stacks->initStream),  "Copying number of steps");

    cudaGetSymbolAddress((void **)&dcoeffs, ALEN);
    CUDA_SAFE_CALL(cudaMemcpyAsync(dcoeffs,  &(batch->accelLen), sizeof(int), cudaMemcpyHostToDevice, batch->stacks->initStream),  "Copying accelLen");
  }

  FOLD // In-mem plane details  .
  {
    if ( batch->flags & FLAG_SS_INMEM  )
    {
      cudaGetSymbolAddress((void **)&dcoeffs, PLN_START);
      CUDA_SAFE_CALL(cudaMemcpyAsync(dcoeffs, &(batch->cuSrch->d_planeFull),  sizeof(void*),  cudaMemcpyHostToDevice, batch->stacks->initStream),  "Copying accelLen");

      cudaGetSymbolAddress((void **)&dcoeffs, PLN_STRIDE);
      CUDA_SAFE_CALL(cudaMemcpyAsync(dcoeffs, &(batch->cuSrch->inmemStride),  sizeof(uint),   cudaMemcpyHostToDevice, batch->stacks->initStream),  "Copying accelLen");
    }
  }

  FOLD // Set other stage specific values  .
  {
    int height[MAX_HARM_NO];
    int stride[MAX_HARM_NO];
    int pStart[MAX_HARM_NO];

    FOLD // Set values  .
    {
      for (int i = 0; i < batch->noGenHarms; i++)
      {
	int sIdx  = batch->cuSrch->sIdx[i];
	height[i] = batch->hInfos[sIdx].noZ;
	stride[i] = batch->hInfos[sIdx].width;
	pStart[i] = batch->hInfos[sIdx].kerStart;
      }

      FOLD // The rest  .
      {
	presto_interp_acc accuracy = LOWACC;
	if ( batch->flags & FLAG_KER_HIGH )
	  accuracy = HIGHACC;

	for (int i = batch->noGenHarms; i < MAX_HARM_NO; i++)
	{
	  float harmFrac	= HARM_FRAC_FAM[i];
	  double zmax		= cu_calc_required_z<double>(harmFrac, batch->hInfos->zmax,   batch->conf->zRes);
	  double zStart		= cu_calc_required_z<double>(harmFrac, batch->hInfos->zStart, batch->conf->zRes);
	  double zEnd		= cu_calc_required_z<double>(harmFrac, batch->hInfos->zEnd,   batch->conf->zRes);
	  height[i]		= abs(cu_index_from_z<double>(zEnd-zStart, 0, batch->conf->zRes));
	  stride[i]		= cu_calc_fftlen<double>(harmFrac, zmax, batch->accelLen, accuracy, batch->conf->noResPerBin, batch->conf->zRes);
	  pStart[i]		= -1;
	}
      }
    }

    cudaGetSymbolAddress((void **)&dcoeffs, HEIGHT_STAGE);
    CUDA_SAFE_CALL(cudaMemcpyAsync(dcoeffs, &height, MAX_HARM_NO * sizeof(int), cudaMemcpyHostToDevice, batch->stacks->initStream),      "Copying stages to device");

    cudaGetSymbolAddress((void **)&dcoeffs, STRIDE_STAGE);
    CUDA_SAFE_CALL(cudaMemcpyAsync(dcoeffs, &stride, MAX_HARM_NO * sizeof(int), cudaMemcpyHostToDevice, batch->stacks->initStream),      "Copying stages to device");

    cudaGetSymbolAddress((void **)&dcoeffs, PSTART_STAGE);
    CUDA_SAFE_CALL(cudaMemcpyAsync(dcoeffs, &pStart, MAX_HARM_NO * sizeof(int), cudaMemcpyHostToDevice, batch->stacks->initStream),      "Copying stages to device");
  }

  CUDA_SAFE_CALL(cudaGetLastError(), "Preparing the constant memory.");

  return (1);
}

void SSKer(cuFFdotBatch* batch)
{
  infoMSG(2,3,"Sum & Search\n");

  PROF // Profiling  .
  {
    NV_RANGE_PUSH("S&S Ker");
  }

  FOLD // Synchronisations  .
  {
    // Current Synchronisations
    for (int ss = 0; ss < batch->noStacks; ss++)
    {
      cuFfdotStack* cStack = &batch->stacks[ss];

      if ( batch->flags & FLAG_SS_INMEM )
      {
	infoMSG(5,5,"Synchronise stream %s on %s stack %i.\n", "srchStream", "ifftMemComp", ss);
	cudaStreamWaitEvent(batch->srchStream, cStack->ifftMemComp,   0);
      }
      else
      {
	infoMSG(5,5,"Synchronise stream %s on %s stack %i.\n", "srchStream", "ifftComp", ss);
	cudaStreamWaitEvent(batch->srchStream, cStack->ifftComp,      0);
      }
    }

    // Previous Synchronisations
    infoMSG(5,5,"Synchronise stream %s on %s.\n", "srchStream", "candCpyComp");
    cudaStreamWaitEvent(batch->srchStream, batch->candCpyComp,      0);
  }

  PROF // Profiling  event .
  {
    if ( batch->flags & FLAG_PROF )
    {
      infoMSG(5,5,"cudaEventRecord %s in stream %s.\n", "searchInit", "srchStream");

      CUDA_SAFE_CALL(cudaEventRecord(batch->searchInit,  batch->srchStream),"Recording event: searchInit");
    }
  }

  FOLD // Call the SS kernel  .
  {
    infoMSG(4,4,"kernel\n");

    if ( batch->retType & CU_POWERZ_S )
    {
      if      ( batch->flags & FLAG_SS_STG )
      {
	add_and_searchCU3(batch->srchStream, batch );
      }
      else if ( batch->flags & FLAG_SS_INMEM )
      {
	add_and_search_IMMEM(batch);
      }
      else
      {
	fprintf(stderr,"ERROR: function %s is not setup to handle this type of search.\n",__FUNCTION__);
	exit(EXIT_FAILURE);
      }
    }
    else
    {
      fprintf(stderr,"ERROR: function %s is not setup to handle this type of return data for GPU accel search\n",__FUNCTION__);
      exit(EXIT_FAILURE);
    }
    CUDA_SAFE_CALL(cudaGetLastError(), "At SSKer kernel launch");
  }

  FOLD // Synchronisation  .
  {
    infoMSG(5,5,"cudaEventRecord %s in stream %s.\n", "searchComp", "srchStream");

    CUDA_SAFE_CALL(cudaEventRecord(batch->searchComp,  batch->srchStream),"Recording event: searchComp");
  }

  PROF // Profiling  .
  {
    NV_RANGE_POP("S&S Ker");
  }
}

/** Process an individual candidate  .
 *
 */
static inline int procesCanidate(resultData* res, double rr, double zz, double poww, double sig, int stage, int numharm)
{
  cuSearch*	cuSrch	= res->cuSrch;

  if ( floor(rr) < cuSrch->sSpec->searchRHigh )
  {
    // NOTE: I tested only doing the sigma calculations after doing a check against the power and harmonics in the area of the result, it was slightly faster (~4%) not enough to warrant it
    sig     = candidate_sigma_cu(poww, numharm, cuSrch->numindep[stage]);

    if      ( res->cndType & CU_STR_LST     )
    {
      if ( res->flags & FLAG_CAND_THREAD )
      {
	// Thread safe
	pthread_mutex_lock(&cuSrch->threasdInfo->candAdd_mutex);
	GSList *candsGPU	= (GSList*)cuSrch->h_candidates;
	int     added		= 0;
	cuSrch->h_candidates	= insert_new_accelcand(candsGPU, poww, sig, numharm, rr, zz, &added );
	(*res->noResults)++;
	pthread_mutex_unlock(&cuSrch->threasdInfo->candAdd_mutex);
      }
      else
      {
	GSList *candsGPU	= (GSList*)cuSrch->h_candidates;
	int     added		= 0;
	cuSrch->h_candidates	= insert_new_accelcand(candsGPU, poww, sig, numharm, rr, zz, &added );
	(*res->noResults)++;
      }
    }
    else if ( res->cndType & CU_STR_ARR     )
    {
      double  	rDiff = rr - cuSrch->sSpec->searchRLow ;
      long long	grIdx;   /// The index of the candidate in the global array

      grIdx = round(rDiff*res->candRRes);

      if ( grIdx >= 0 && grIdx < cuSrch->candStride )		// Valid index  .
      {
	if ( res->flags & FLAG_STORE_ALL )			// Store all stages  .
	{
	  grIdx += stage * (cuSrch->candStride);		// Stride by size
	}

	if ( res->cndType & CU_CANDFULL )
	{
	  initCand* candidate = &((initCand*)cuSrch->h_candidates)[grIdx];

	  // this sigma is greater than the current sigma for this r value
	  if ( candidate->sig < sig )
	  {
	    if ( res->flags & FLAG_CAND_THREAD )
	    {
	      pthread_mutex_lock(&cuSrch->threasdInfo->candAdd_mutex);
	      if ( candidate->sig < sig ) // Check again
	      {
		if ( candidate->sig == 0 )
		  (*res->noResults)++;

		candidate->sig      = sig;
		candidate->power    = poww;
		candidate->numharm  = numharm;
		candidate->r        = rr;
		candidate->z        = zz;
	      }
	      pthread_mutex_unlock(&cuSrch->threasdInfo->candAdd_mutex);
	    }
	    else
	    {
	      if ( candidate->sig == 0 )
	        (*res->noResults)++;

	      candidate->sig      = sig;
	      candidate->power    = poww;
	      candidate->numharm  = numharm;
	      candidate->r        = rr;
	      candidate->z        = zz;
	    }
	  }
	}
	else
	{
	  fprintf(stderr,"ERROR: function %s requires storing full candidates.\n",__FUNCTION__);
	  exit(EXIT_FAILURE);
	}
      }
      else
      {
	// NOTE: The standard search sets the first family of ff planes to start at the scaled start R, thus the harmonics of this (harmonics go down) may have r values below the start r
      }
    }
    else if ( res->cndType & CU_STR_QUAD    )
    {
      candTree* qt = (candTree*)cuSrch->h_candidates;

      initCand* candidate     	= new initCand;

      candidate->sig      	= sig;
      candidate->power    	= poww;
      candidate->numharm  	= numharm;
      candidate->r        	= rr;
      candidate->z        	= zz;

      (*res->noResults)++;

      qt->insert(candidate);
    }
    else
    {
      fprintf(stderr,"ERROR: Function %s unknown candidate storage type.\n", __FUNCTION__);
      exit(EXIT_FAILURE);
    }
  }

  return (0);
}

/** Process the results of the search this is usually run in a separate CPU thread  .
 *
 * This function is meant to be the entry of a separate thread
 *
 */
void* processSearchResults(void* ptr)
{
  struct 	timeval start, end;      		// Profiling variables
  resultData*	res	= (resultData*)ptr;
  cuSearch*	cuSrch	= res->cuSrch;
  double	poww, sig;
  double	rr, zz;
  int		numharm;
  int		idx;
  void*		localResults = res->retData;

  PROF // Profiling  .
  {
    if ( res->flags & FLAG_PROF )
    {
      gettimeofday(&start, NULL); // But can time time processing of the results so start the clock...
    }
  }

  FOLD // Main loop, looping over returned values
  {
    for ( int stage = 0; stage < cuSrch->noHarmStages; stage++ )
    {
      numharm       = (1<<stage);
      float cutoff  = cuSrch->powerCut[stage];

      for ( int y = res->y0; y < res->y1; y++ )
      {
	for ( int x = res->x0; x < res->x1; x++ )
	{
	  poww      = 0;
	  sig       = 0;
	  zz        = 0;

	  idx = stage*res->xStride*res->yStride + y*res->xStride + x ;

	  // TODO: Try putting these if statements outside the loop

	  if      ( res->retType & CU_CANDMIN     )
	  {
	    candMin candM         = ((candMin*)localResults)[idx];

	    if ( candM.power > poww )
	    {
	      sig                 = candM.power;
	      poww                = candM.power;
	      zz                  = candM.z;
	    }
	  }
	  else if ( res->retType & CU_POWERZ_S    )
	  {
	    candPZs candM         = ((candPZs*)localResults)[idx];

	    if ( candM.value > poww )
	    {
	      sig                 = candM.value;
	      poww                = candM.value;
	      zz                  = candM.z;
	    }
	  }
	  else if ( res->retType & CU_CANDBASC    )
	  {
	    accelcandBasic candB  = ((accelcandBasic*)localResults)[idx];

	    if ( candB.sigma > poww )
	    {
	      poww                = candB.sigma;
	      sig                 = candB.sigma;
	      zz                  = candB.z;
	    }
	  }
	  else if ( res->retType & CU_FLOAT       )
	  {
	    float val  = ((float*)localResults)[idx];

	    if ( val > cutoff )
	    {
	      poww                = val;
	      sig                 = val;
	      zz                  = y;
	    }
	  }
	  else if ( res->retType & CU_HALF        )
	  {
	    float val  = half2float( ((ushort*)localResults)[idx] );

	    if ( val > cutoff )
	    {
	      poww                  = val;
	      sig                   = val;
	      zz                    = y;
	    }
	  }
	  else
	  {
	    fprintf(stderr,"ERROR: function %s requires accelcandBasic\n",__FUNCTION__);
	    if ( res->flags & FLAG_CAND_THREAD )
	    {
	      sem_trywait(&(cuSrch->threasdInfo->running_threads));
	    }
	    exit(EXIT_FAILURE);
	  }

	  if ( poww > 0 )
	  {
	    // This value is above the threshold
	    if ( zz < 0 || zz >= res->noZ )
	    {
	      fprintf(stderr,"ERROR: Invalid z value found at bin %.2f.\n", rr);
	    }
	    else
	    {
	      // Calculate r and z value
	      rr  = ( res->rLow + x / (double) res->noResPerBin )  / (double)numharm ;
	      zz  = (res->zStart + (res->zEnd - res->zStart ) * zz / (double)(res->noZ-1) ) ;
	      zz /= (double)numharm ;
	      if ( res->noZ == 1 )
		zz = 0;

	      if ( isnan(poww) )
	      {
		fprintf(stderr, "CUDA search returned an NAN power at bin %.3f.\n", rr);
	      }
	      else
	      {
		if ( isinf(poww) )
		{
		  if ( res->flags & FLAG_POW_HALF )
		  {
		    poww          = 6.55e4;      // Max 16 bit float value
		    fprintf(stderr,"WARNING: Search return inf power at bin %.2f, dropping to %.2e. If this persists consider using single precision floats.\n", rr, poww);
		  }
		  else
		  {
		    poww          = 3.402823e38; // Max 32 bit float value
		    fprintf(stderr,"WARNING: Search return inf power at bin %.2f. This is probably an error as you are using single precision floats.\n", rr);
		  }
		}

		procesCanidate(res, rr, zz, poww, sig, stage, numharm ) ;
	      }
	    }
	  }
	}
      }
    }
  }

  FOLD // Thread memory  .
  {
    if ( res->flags & FLAG_CAND_MEM_PRE )
    {
      freeNull(localResults);
    }
    else
    {
      // Mark the pinned memory as free
      *res->outBusy = false;
    }
  }

  // Decrease the count number of running threads
  if ( res->flags & FLAG_CAND_THREAD )
  {
    sem_trywait(&(cuSrch->threasdInfo->running_threads));
  }

  PROF // Profiling  .
  {
    if ( res->flags & FLAG_PROF )
    {
      gettimeofday(&end, NULL);
      float time =  (end.tv_sec - start.tv_sec) * 1e6 + (end.tv_usec - start.tv_usec);

      if ( res->flags & FLAG_CAND_THREAD )
      {
	pthread_mutex_lock(&cuSrch->threasdInfo->candAdd_mutex);
	res->resultTime[0] += time;
	pthread_mutex_unlock(&cuSrch->threasdInfo->candAdd_mutex);
      }
      else
      {
	res->resultTime[0] += time;
      }
    }
  }

  FOLD // Free memory  .
  {
    freeNull(res);
  }

  return (NULL);
}

/** Process the search results for the batch  .
 * This usually spawns a separate CPU thread to do the sigma calculations
 */
void processBatchResults(cuFFdotBatch* batch)
{
  rVals* rVal	= &((*batch->rAraays)[batch->rActive][0][0]);
  int tSum	= 1;			// Check everything by default

  if ( rVal->numrs )
  {
    struct timeval start, end;		// Profiling variables
    resultData* thrdDat;		// Structure to pass to the thread

    infoMSG(2,2,"Process results - Iteration %3i.", rVal->iteration);

    PROF // Profiling  .
    {
      NV_RANGE_PUSH("CPU Process results");

      if ( batch->flags & FLAG_PROF )
      {
	gettimeofday(&start, NULL);
      }
    }

    FOLD // Allocate temporary memory to copy results back to  .
    {
      infoMSG(4,4,"Allocate thread memory");

      thrdDat = new resultData;		// A data structure to hold info for the thread processing the results
      memset(thrdDat, 0, sizeof(resultData) );
    }

    FOLD // Initialise data structure  .
    {
      infoMSG(3,3,"Initialise thread data structure");

      thrdDat->cuSrch		= batch->cuSrch;
      thrdDat->cndType		= batch->cndType;
      thrdDat->retType		= batch->retType;
      thrdDat->flags		= batch->flags;
      thrdDat->resultTime	= &batch->compTime[NO_STKS*COMP_GEN_STR];
      thrdDat->blockTime	= NULL;
      thrdDat->noResults	= &batch->noResults;
      thrdDat->preBlock		= batch->candCpyComp;

      thrdDat->rLow		= rVal->drlo;
      thrdDat->noResPerBin	= batch->conf->noResPerBin;
      thrdDat->candRRes		= batch->conf->candRRes;

      thrdDat->noZ		= batch->hInfos->noZ;
      thrdDat->zStart		= batch->hInfos->zStart;
      thrdDat->zEnd		= batch->hInfos->zEnd;

      thrdDat->x0		= 0;
      thrdDat->x1		= 0;
      thrdDat->y0		= 0;
      thrdDat->y1		= batch->ssSlices;

      thrdDat->xStride		= batch->strideOut;
      thrdDat->yStride		= batch->ssSlices;

      thrdDat->resSize		= batch->retDataSize;
      thrdDat->retData		= rVal->h_outData;
      thrdDat->outBusy		= &rVal->outBusy;

      thrdDat->rVal		= *rVal;

      infoMSG(7,7,"Reading data from %p", thrdDat->retData );

      if ( !(batch->flags & FLAG_SS_INMEM) )
      {
	// Multi-step

	thrdDat->xStride	*= batch->noSteps;

	for ( int step = 0; step < batch->noSteps; step++) 	// Loop over steps  .
	{
	  rVals* rVal		= &(*batch->rAraays)[batch->rActive][step][0];
	  thrdDat->x1		+= rVal->numrs;			// These should all be acelllen but there may be the case of the last step!
	}
      }
      else
      {
	// NB: In-mem has only one step
	thrdDat->x1		= rVal->numrs;
      }

      if ( thrdDat->x1 > thrdDat->xStride )
      {
	fprintf(stderr,"ERROR: Number of elements of greater than stride. In function %s  \n",__FUNCTION__);
	exit(EXIT_FAILURE);
      }
    }

    PROF // Profiling  .
    {
      if ( batch->flags & FLAG_PROF )
      {
	gettimeofday(&end, NULL);
	float time = (end.tv_sec - start.tv_sec) * 1e6 + (end.tv_usec - start.tv_usec);
	int idx = MIN(2, batch->noStacks-1);

	batch->compTime[NO_STKS*COMP_GEN_STR+idx] += time;
      }
    }

    FOLD // A blocking synchronisation to ensure results are ready to be proceeded by the host  .
    {
      infoMSG(4,4,"Blocking synchronisation on %s", "candCpyComp" );

      PROF // Profiling  .
      {
	NV_RANGE_PUSH("EventSynch");
      }

      CUDA_SAFE_CALL(cudaEventSynchronize(batch->candCpyComp), "At a blocking synchronisation. This is probably a error in one of the previous asynchronous CUDA calls.");

      PROF // Profiling  .
      {
	NV_RANGE_POP("EventSynch");
      }
    }

    FOLD // Counts of candidates  .
    {
#ifdef WITH_SAS_COUNT
      if ( batch->flags & FLAG_SS_COUNT)
      {
	int* blockCounts = (int*)((char*)thrdDat->retData + batch->cndDataSize);
	tSum = 0;
	
	for ( int i = 0; i < rVal->noBlocks; i++)
	{
	  tSum += blockCounts[i];
	}
      }
#endif
    }

    FOLD // ADD candidates to global list potently in a separate thread  .
    {
      if ( tSum)	// Only check results if there candidates....
      {
	// I found the overhead of spawning threads became significant when few harmonics (1) are summed
	// This skips all candidate overhead if no candidates were found

	infoMSG(6,6,"Found %i candidates", tSum );

	FOLD  //  Thread memory  .
	{
	  if ( batch->flags & FLAG_CAND_MEM_PRE )
	  {
	    // Allocate temporary thread specific memory
	    thrdDat->retData = (void*)malloc(thrdDat->resSize);

	    // Copy candidates from pinned memory to temporary thread memory
	    memcpy(thrdDat->retData, rVal->h_outData, thrdDat->resSize);

	    // Mark pinned memory as free
	    rVal->outBusy = false;
	  }
	}

	if ( batch->flags & FLAG_CAND_THREAD ) 	// Create thread  .
	{
	  infoMSG(3,3,"Spawn thread");

	  PROF // Profiling  .
	  {
	    NV_RANGE_PUSH("Thread");
	  }

	  sem_post(&batch->cuSrch->threasdInfo->running_threads); // Increase the count number of running threads, processSearchResults will decrease it when its finished

	  pthread_t thread;
	  int  iret1 = pthread_create( &thread, NULL, processSearchResults, (void*) thrdDat);

	  if (iret1)
	  {
	    fprintf(stderr,"Error - pthread_create() return code: %d\n", iret1);
	    exit(EXIT_FAILURE);
	  }

	  if ( batch->flags & FLAG_SYNCH )
	  {
	    void *status;
	    if ( pthread_join(thread, &status) )
	    {
	      fprintf(stderr,"ERROR: Failed to join results thread.\n");
	      exit(EXIT_FAILURE);
	    }
	  }

	  PROF // Profiling  .
	  {
	    NV_RANGE_POP("Thread");
	  }
	}
	else                              	// Just call the function  .
	{
	  infoMSG(3,3,"Non thread");

	  PROF // Profiling  .
	  {
	    NV_RANGE_PUSH("Non thread");
	  }

	  processSearchResults( (void*) thrdDat );

	  PROF // Profiling  .
	  {
	    NV_RANGE_POP("Non thread");
	  }
	}
      }
      else
      {
	// No candidates so mark memory as free
	rVal->outBusy = false;
      }

      FOLD // Synchronisation  .
      {
	infoMSG(5,5,"cudaEventRecord %s in stream %s.\n", "processComp", "srchStream");

	// This will allow kernels to run while the CPU continues
	CUDA_SAFE_CALL(cudaEventRecord(batch->processComp, batch->srchStream),"Recording event: processComp");
      }
    }

    PROF // Profiling  .
    {
      NV_RANGE_POP("CPU Process results");
    }
  }
}

void getResults(cuFFdotBatch* batch)
{
  PROF // Profiling - Time previous components  .
  {
    NV_RANGE_PUSH("Get results");

    if ( (batch->flags & FLAG_PROF) )
    {
      if ( (*batch->rAraays)[batch->rActive+1][0][0].numrs )
      {
	// Results copying
	timeEvents( batch->candCpyInit, batch->candCpyComp, &batch->compTime[NO_STKS*COMP_GEN_D2H],   "Copy device to host");
      }
    }
  }

  rVals* rVal = &(((*batch->rAraays)[batch->rActive])[0][0]);

  if ( rVal->numrs )
  {
    infoMSG(2,2,"Get batch results - Iteration %3i.", rVal->iteration);

    FOLD // Synchronisations  .
    {
      infoMSG(5,5,"Synchronise stream %s on %s.\n", "resStream", "searchComp");

      // This iteration
      CUDA_SAFE_CALL(cudaStreamWaitEvent(batch->resStream, batch->searchComp,  0),"Waiting on event searchComp");

      FOLD // Spin CPU until pinned memory is free from the previous iteration  .
      {
	if ( rVal->outBusy )
	{
	  infoMSG(6,6,"Waiting on pinned memory to be free (%p).\n", &rVal->outBusy);

	  PROF // Profiling - Time previous components  .
	  {
	    NV_RANGE_PUSH("Spin");
	  }

	  while( rVal->outBusy )
	  {
	    // TODO: Should probably put a time out here  .
	    usleep(1);
	  }

	  PROF // Profiling  .
	  {
	    NV_RANGE_POP("Get results");
	  }
	}

	// NB: This marks the output as busy, the data hasn't been copied but nothing should touch it from this point, there will still be a synchronisation to make sure the data is copied before work is done one it.
	infoMSG(6,6,"Marking pinned memory as busy (%p).\n", &rVal->outBusy);
	rVal->outBusy = true;

      }
    }

    PROF // Profiling  .
    {
      if ( batch->flags & FLAG_PROF )
      {
	infoMSG(5,5,"cudaEventRecord %s in stream %s.\n", "candCpyInit", "srchStream");

	CUDA_SAFE_CALL(cudaEventRecord(batch->candCpyInit,  batch->srchStream),"Recording event: candCpyInit");
      }
    }

    FOLD // Copy relevant data back  .
    {
      infoMSG(4,4,"1D async memory copy D2H");

      if ( rVal->h_outData == NULL )
      {
	fprintf(stderr,"ERROR: Pointer to output data is NULL in %s.\n", __FUNCTION__ );
	exit(EXIT_FAILURE);
      }

      infoMSG(7,7,"Writing data to %p from %p", rVal->h_outData, batch->d_outData1);

      if      ( batch->retType & CU_STR_PLN )
      {
	CUDA_SAFE_CALL(cudaMemcpyAsync(rVal->h_outData, batch->d_planePowr, batch->pwrDataSize, cudaMemcpyDeviceToHost, batch->resStream), "Failed to copy results back");
      }
      else
      {
	CUDA_SAFE_CALL(cudaMemcpyAsync(rVal->h_outData, batch->d_outData1,  batch->retDataSize, cudaMemcpyDeviceToHost, batch->resStream), "Failed to copy results back");
      }

      CUDA_SAFE_CALL(cudaGetLastError(), "Copying results back from device.");
    }

    FOLD // Synchronisations  .
    {
      infoMSG(5,5,"cudaEventRecord %s in stream %s.\n", "candCpyComp", "resStream");

      CUDA_SAFE_CALL(cudaEventRecord(batch->candCpyComp, batch->resStream),"Recording event: readComp");
    }

    CUDA_SAFE_CALL(cudaGetLastError(), "Leaving getResults.");
  }

  PROF // Profiling  .
  {
    NV_RANGE_POP("Get results");
  }
}

void sumAndSearch(cuFFdotBatch* batch)        // Function to call to SS and process data in normal steps  .
{
  PROF // Profiling - Time previous components  .
  {
    if ( (batch->flags & FLAG_PROF) )
    {
      if ( (*batch->rAraays)[batch->rActive+1][0][0].numrs )
      {
	infoMSG(5,5,"Time previous components");

	// Sum & Search kernel
	timeEvents( batch->searchInit, batch->searchComp, &batch->compTime[NO_STKS*COMP_GEN_SS],   "Sum & Search");
      }
    }
  }

  // Sum and search the IFFT'd data  .
  if ( (*batch->rAraays)[batch->rActive][0][0].numrs )
  {
    infoMSG(2,2,"Sum & Search Batch - Iteration %3i.", (*batch->rAraays)[batch->rActive][0][0].iteration);

    if      ( batch->retType	& CU_STR_PLN 	  )
    {
      // Nothing!
    }
    else if ( batch->flags	& FLAG_SS_INMEM )
    {
      // NOTHING
    }
    else if ( batch->flags	& FLAG_SS_CPU   )
    {
      // NOTHING
    }
    else
    {
      SSKer(batch);
    }
  }
}

void sumAndMax(cuFFdotBatch* batch)
{
  // TODO write this
}

void inmemSS(cuFFdotBatch* batch, double drlo, int len)
{
  PROF
  {
    setActiveIteration(batch, 0);
    rVals* rVal = &((*batch->rAraays)[batch->rActive][0][0]);
    infoMSG(1,1,"\nIteration %4i - Start step %4i   processing %02i steps on GPU %i - Start bin: %9.2f \n", rVal->iteration, rVal->step, 1, batch->gInf->devid, rVal->drlo );
  }

  setActiveIteration(batch, 0);
  setSearchRVals(batch, drlo, len);

  // Synchronous and asynchronous execution have the same ordering
  setActiveIteration(batch, 0);
  add_and_search_IMMEM(batch);

  setActiveIteration(batch, 1);
  processBatchResults(batch);

  setActiveIteration(batch, 0);
  getResults(batch);

  // Cycle r values
  cycleRlists(batch);
  setActiveIteration(batch, 1); // Set active batch to 1, why?

  // Cycle candidate output - Flip / flop device memory
  cycleOutput(batch);
}

void inmemSumAndSearch(cuSearch* cuSrch)
{
  infoMSG(1,1,"Inmem Sum And Search\n");

  struct timeval start01, start02, end;
  cuFFdotBatch* master	= &cuSrch->pInf->kernels[0];   // The first kernel created holds global variables

  double startr		= 0;				/// The first bin to start searching at
  double cuentR		= 0;				/// The start bin of the input FFT to process next
  double noR		= 0;				/// The number of input FFT bins the search covers
  int iteration		= 0;
  int step		= 0;

  // Search bounds
  startr		= cuSrch->sSpec->searchRLow;
  noR			= cuSrch->sSpec->noSearchR;
  cuentR 		= startr;

  TIME // Timing  .
  {
    gettimeofday(&start01, NULL);
    NV_RANGE_PUSH("GPU IMSS");
  }

  FOLD // Set all r-values to zero  .
  {
    for ( int bIdx = 0; bIdx < cuSrch->pInf->noBatches; bIdx++ )
    {
      cuFFdotBatch* batch = &cuSrch->pInf->batches[bIdx];
      clearRvals(batch);
    }
  }

#if	!defined(DEBUG) && defined(WITHOMP)   // Parallel if we are not in debug mode  .
  if ( cuSrch->conf->gen->flags & FLAG_SYNCH )
  {
    omp_set_num_threads(1);
  }
  else
  {
    omp_set_num_threads(cuSrch->pInf->noBatches);
  }

#pragma omp parallel
#endif	// !DEBUG && WITHOMP
  FOLD  //                              ---===== Main Loop =====---  .
  {
    int tid = 0;
#ifdef	WITHOMP
    tid = omp_get_thread_num();
#endif	// WITHOMP

    cuFFdotBatch* batch = &cuSrch->pInf->batches[tid];

    setDevice(batch->gInf->devid) ;

    // Make sure kernel create and all constant memory reads and writes are complete
    CUDA_SAFE_CALL(cudaDeviceSynchronize(), "Synchronising device before candidate generation");

    int		firstStep	= 0;							///< Thread specific value for the first step the batch is processing
    double	firstR		= 0;							///< Thread specific value for the first input FT bin index being searched
    int		ite		= 0;							///< The iteration the batch is working on (local to each thread)
    double	len      	= 0;							///< The length in expanded bins of the section being searched over - This can be depricated

    while ( cuentR < cuSrch->sSpec->searchRHigh )  //			---===== Main Loop =====---  .
    {
#pragma omp critical
      FOLD // Calculate the step  .
      {
	FOLD  // Synchronous behaviour  .
	{
#ifndef  DEBUG
	  if ( cuSrch->conf->gen->flags & FLAG_SYNCH )
#endif
	  {
	    // If running in synchronous mode use multiple batches, just synchronously
	    tid     = iteration % cuSrch->pInf->noBatches ;
	    batch   = &cuSrch->pInf->batches[tid];
	    setDevice(batch->gInf->devid) ;
	  }
	}

	iteration++;
	ite 		= iteration;
	firstStep	= iteration;
	step		+= 1;
	firstR		= cuentR;
	cuentR		+= batch->strideOut / (double)cuSrch->conf->gen->noResPerBin ;
      }
      
      FOLD // Set other thread specific values  .
      {
	len         	= MIN(batch->strideOut, (cuSrch->sSpec->searchRHigh - firstR)*cuSrch->conf->gen->noResPerBin) ;
	rVals* rVal 	= &(*batch->rAraays)[0][0][0];
	rVal->drlo	= firstR;
	rVal->drhi	= firstR + len / cuSrch->conf->gen->noResPerBin ;
	rVal->step  	= firstStep;
	rVal->iteration	= ite;
      }

      inmemSS(batch, firstR, len);

#pragma omp critical
      FOLD // Output  .
      {
	if ( msgLevel == 0  )
	{
	  double per = (cuentR - startr)/noR *100.0;
	  int noTrd;
	  sem_getvalue(&master->cuSrch->threasdInfo->running_threads, &noTrd );
	  printf("\rSearching  in-mem GPU plane. %5.1f%% ( %3i Active CPU threads processing found candidates)  ", per, noTrd );
	  fflush(stdout);
	}
	else
	{

	}
      }

    }

    FOLD // Finish off the search  .
    {
      infoMSG(1,0,"\nFinish off the search.\n" );

      for ( int step = 0 ; step < batch->noRArryas; step++ )
      {
	inmemSS(batch, 0, 0);
      }

#ifndef  DEBUG
      if ( cuSrch->conf->gen->flags & FLAG_SYNCH )
#endif
      {
	// If running in synchronous mode use multiple batches, just synchronously so clear all batches
	for ( int bId = 0; bId < cuSrch->pInf->noBatches; bId++ )
	{
	  infoMSG(1,0,"\nFinish off search (synch batch %i).\n", bId);

	  batch = &cuSrch->pInf->batches[bId];

	  for ( int step = 0 ; step < batch->noRArryas; step++ )
	  {
	    inmemSS(batch, 0, 0);
	  }
	}
      }
    }
  }

  printf("\rSearching  in-mem GPU plane. %5.1f%%                                                                                    \n\n", 100.0 );

  TIME //  Timing  .
  {
    gettimeofday(&start02, NULL);
  }

  FOLD // Wait for all processing threads to terminate
  {
    waitForThreads(&master->cuSrch->threasdInfo->running_threads, "Waiting for CPU thread(s) to finish processing returned from the GPU.", 200 );
  }

  TIME // Timing  .
  {
    NV_RANGE_POP("GPU IMSS");
    gettimeofday(&end, NULL);
    cuSrch->timings[TIME_GPU_SS] += (end.tv_sec - start01.tv_sec) * 1e6 + (end.tv_usec - start01.tv_usec);
    cuSrch->timings[TIME_GEN_WAIT] += (end.tv_sec - start02.tv_sec) * 1e6 + (end.tv_usec - start02.tv_usec);
  }
}
