#include "cuda_accel_SS.h"

#include <cufft.h>
#include <algorithm>

#include <thrust/sort.h>
#include <thrust/device_vector.h>
#include <nvToolsExt.h>
#include <nvToolsExtCudaRt.h>

#include "cuda_accel.h"
#include "cuda_utils.h"
#include "cuda_accel_utils.h"
#include "cuda_accel_SS.h"


void add_and_search_CPU(cuFFdotBatch* batch )
{
  infoMSG(2,2,"Sum & Search CPU\n");

  // Timing  variables
  struct timeval start, end;

  const int noStages    = batch->noHarmStages;
  const int noHarms     = batch->noGenHarms;
  const int noSteps     = batch->noSteps;
  const int64_t FLAGS   = batch->flags;
  const int zeroHeight  = batch->hInfos->height;

  float*      pwerPlnF[noHarms];
  fcomplexcu* pwerPlnC[noHarms];

  candPZs     candLists [noStages][noSteps];
  float       pow[noHarms][noSteps];
  short       iyP[noHarms];
  int         inds[noHarms];
  int         sliceSz   = 16;
  int         noSlices  = ceil( zeroHeight / (float)sliceSz );
  int         noCands   = 0;
  cand*       cnd       = (cand*)malloc(sizeof(cand)*noSlices*batch->accelLen*noStages*noSteps);

  FOLD // Sum search data  .
  {
    nvtxRangePush("CPU Sum & search");

    if ( batch->flags & FLAG_TIME ) // Timing  .
      gettimeofday(&start, NULL);

    FOLD // Prep - Initialise the x indices  .
    {
      int bace = 0;
      for ( int harm = 0; harm < noHarms; harm++ )                  // loop over harmonic  .
      {
        int stgIDX = batch->sInf->sIdx[harm];

        pwerPlnF[stgIDX] = &((float*)batch->h_outData1)[bace];
        pwerPlnC[stgIDX] = &((fcomplexcu*)batch->h_outData1)[bace];

        bace += batch->hInfos[harm].height * batch->stacks[batch->hInfos[harm].stackNo].stridePower * noSteps;
      }
    }

    for ( int ix = 0; ix < batch->accelLen; ix++ )
    {
      FOLD // Prep - Initialise the x indices  .
      {
        for ( int harm = 0; harm < noHarms; harm++ )                // loop over harmonic  .
        {
          int stgIDX        = batch->sInf->sIdx[harm];
          cuHarmInfo* hInf  = &batch->hInfos[stgIDX];

          //// NOTE: the indexing below assume each plane starts on a multiple of noHarms
          int   hIdx        = round( ix*hInf->harmFrac ) + hInf->kerStart;
          inds[harm]        = hIdx;
        }
      }

      FOLD // Set the local and return candidate powers to zero  .
      {
        for ( int stage = 0; stage < noStages; stage++ )
        {
          for ( int step = 0; step < noSteps; step++)               // Loop over steps  .
          {
            candLists[stage][step].value = batch->sInf->powerCut[stage] ;
          }
        }
      }

      FOLD // Set hold values to zero
      {
        for ( int harm = 0; harm < noHarms; harm++ )
        {
          iyP[harm] = -1;
        }
      }

      FOLD // Sum & Search - Ignore contaminated ends tid to start at correct spot  .
      {
        for( int y = 0, sy = 0; y < zeroHeight; y++, sy++ )         // Loop over the chunk  .
        {
          float powers[noSteps];
          for ( int step = 0; step < noSteps; step++)               // Loop over steps  .
          {
            powers[step] = 0;
          }

          for ( int stage = 0 ; stage < noStages; stage++)          // Loop over stages  .
          {
            short start         = STAGE_CPU[stage][0] ;
            short end           = STAGE_CPU[stage][1] ;

            for ( int harm = start; harm <= end; harm++ )         	// Loop over harmonics (batch) in this stage  .
            {
              int stgIDX            = batch->sInf->sIdx[harm];
              cuHarmInfo* hInf      = &batch->hInfos[stgIDX];
              cuFfdotStack* cStack  = &batch->stacks[ batch->hInfos[stgIDX].stackNo ];
              int     ix1           = inds[harm] ;
              int     ix2           = ix1;
              short   iy1           = batch->sInf->yInds[ (zeroHeight+INDS_BUFF)*harm + y ];

              if ( iyP[harm] != iy1 ) // Only read power if it is not the same as the previous  .
              {
                for ( int step = 0; step < noSteps; step++ )        // Loop over steps  .
                {
                  int iy2;

                  FOLD // Calculate index  .
                  {
                    if        ( FLAGS & FLAG_ITLV_ROW )
                    {
                      ix2 = ix1 + step    * cStack->strideCmplx;
                      iy2 = iy1 * noSteps * cStack->strideCmplx;
                    }
                    else
                    {
                      iy2 = ( iy1 + step * hInf->height ) * cStack->strideCmplx ;
                    }
                  }

                  FOLD // Read powers  .
                  {
                    if      ( FLAGS & FLAG_CUFFT_CB_POW )
                    {
                      pow[harm][step]         = pwerPlnF[harm][ iy2 + ix2 ];
                    }
                    else
                    {
                      fcomplexcu cmpc         = pwerPlnC[harm][ iy2 + ix2 ];
                      pow[harm][step]         = cmpc.r * cmpc.r + cmpc.i * cmpc.i;
                    }
                  }

                }
                iyP[harm] = iy1;
              }

              for ( int step = 0; step < noSteps; step++)           // Loop over steps  .
              {
                powers[step]  += pow[harm][step];
              }
            }

            for ( int step = 0; step < noSteps; step++)             // Loop over steps  .
            {
              if ( powers[step] > candLists[stage][step].value )
              {
                // This is our new max!
                candLists[stage][step].value  = powers[step];
                candLists[stage][step].z      = y;
              }
            }
          }

          if ( sy > sliceSz || y == zeroHeight - 1 )
          {
            FOLD // Add candidates to list  .
            {
              for ( int stage = 0 ; stage < noStages; stage++)      // Loop over stages  .
              {
                for ( int step = 0; step < noSteps; step++)         // Loop over steps  .
                {
                  if ( candLists[stage][step].value > batch->sInf->powerCut[stage] )
                  {
                    rVals* rVal = &(*batch->rAraays)[batch->rActive][step][0];

                    int numharm   = (1<<stage);
                    double rr     = rVal->drlo + ix *  ACCEL_DR ;

                    //procesCanidate(batch, rr, y, candLists[stage][step].value, 0, stage, numharm );
                    cnd[noCands].numharm  = numharm;
                    cnd[noCands].power    = candLists[stage][step].value;
                    cnd[noCands].r        = rr;
                    cnd[noCands].sig      = 0;
                    cnd[noCands].z        = y;
                    noCands++;
                  }
                }
              }
            }

            FOLD // Set the local and return candidate powers to zero  .
            {
              for ( int stage = 0; stage < noStages; stage++ )
              {
                for ( int step = 0; step < noSteps; step++)         // Loop over steps  .
                {
                  candLists[stage][step].value = 0 ;
                }
              }
            }

            sy = 0;
          }
        }
      }
    }

    if ( batch->flags & FLAG_TIME ) // Timing  .
    {
      gettimeofday(&end, NULL);
      float v1 =  ((end.tv_sec - start.tv_sec) * 1e6 + (end.tv_usec - start.tv_usec))*1e-3  ;
      batch->searchTime[0] += v1;
    }

    nvtxRangePop();
  }

  FOLD // Process candidates  .
  {
    nvtxRangePush("CPU Process results");

    if ( batch->flags & FLAG_TIME ) // Timing  .
      gettimeofday(&start, NULL);

    for ( int c = 0; c < noCands; c++ )
    {
      int stage = log2((float)cnd[c].numharm);
      //procesCanidate(batch, cnd[c].r, cnd[c].z, cnd[c].power, 0, stage, cnd[c].numharm );
    }

    if ( batch->flags & FLAG_TIME ) // Timing  .
    {
      gettimeofday(&end, NULL);
      float v2 =  ((end.tv_sec - start.tv_sec) * 1e6 + (end.tv_usec - start.tv_usec))*1e-3  ;
      batch->resultTime[0] += v2;
    }

    nvtxRangePop();
  }

  free(cnd);
}
