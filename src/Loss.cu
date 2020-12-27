#include "../include/Loss.cuh"
#include <stdlib.h>
#include <vector>
#include <iostream>

// block size will always be 512 in this file

__global__ void reduce(double out, double *in, int len)
{
	extern __shared__ double values[];

	double *tmp = new double[gridDim.x * gridDim.y];

	int idx = blockDim.x * threadIdx.y + threadIdx.x;

	int g_idx = gridDim.x * blockDim.x * (blockDim.y * blockIdx.y + threadIdx.y)
		+ blockDim.x * blockIdx.x + threadIdx.x;

	// abort if thread is extra in block
	if (g_idx >= len)
		return;

	// load shared memory array from global memory
	values[idx] = in[g_idx];

	// takes upper half of array and adds it to corresponding elements in lower half
	// does this repeatedly until relevant part of array is one elem
	// 	therefore there are no halves to add
	for (unsigned int i = blockDim.x * blockDim.y / 2; i > 0; i >>= 1)
	{
		if (idx < i)
			values[idx] += values[idx + i];

		__syncthreads();
	} // end for

	// write sum of this portion of array to corresponding index in out
	// all threads will be writing the same value, so we don't need to 
	//	worry about a race condition
	tmp[blockIdx.y * gridDim.x + blockIdx.x] = values[0];

	// if more than one block was used, meaning each block reduced part of array,
	// 	we must reduce further, so call again 
	if (gridDim.x * gridDim.y > 1)
		reduce<<<dim3(len / 512 + 1), dim3(512), (len / 512 + 1) * sizeof(double)>>>(out, tmp, len);
	else
		out = tmp[0];

} // end reduce

// extern means reduce declared elsewhere
// for this application that means its len will be determined based on how much
// 	shared memory we give each block
__global__ void squares(double *sqr, double *x, double *y, int len)
{
	int g_idx = gridDim.x * blockDim.x * (blockDim.y * blockIdx.y + threadIdx.y)
		+ blockDim.x * blockIdx.x + threadIdx.x;
	// first line finds number of threads in rows of grid above thread's row 
	// second line finds how far into row thread is
	// so it puts matrix of threads into row major form
	// note that if we have 1d vect of threads, this reduces to threadIdx.x

	// abort if extra thread in block
	if (g_idx >= len)
		return;

	// get array of square differences
	sqr[g_idx] = (x[g_idx] - y[g_idx]) * (x[g_idx] - y[g_idx]);

} // end mse

std::vector<double> mseGPU(double *x, double *y, int size, int e_size) 
{
	double *tmp;
	double *d_err, *d_sqr, *d_x, *d_y;
	std::vector<double> err(e_size);

	cudaMalloc((void **) &d_err, e_size * sizeof(double));
	cudaMalloc((void **) &d_sqr, size * e_size * sizeof(double));
	cudaMalloc((void **) &d_x, size * e_size * sizeof(double));
	cudaMalloc((void **) &d_y, size * e_size * sizeof(double));

	cudaMemcpy(d_x, x, size * sizeof(double), cudaMemcpyHostToDevice);
	cudaMemcpy(d_y, y, size * sizeof(double), cudaMemcpyHostToDevice);

	dim3 sqrGRID(size * e_size / 512 + 1);
	dim3 sqrBLOCK(512);

	dim3 redGRID(size / 512 + 1);
	dim3 redBLOCK(512);

	squares<<<sqrGRID, sqrBLOCK, 0>>>(d_sqr, d_x, d_y, size * e_size);
	
	for (int i = 0; i < e_size; i++)
	{
		std::cout << "HERE" << i << std::endl;
		tmp = d_sqr + i * size; // it will move through each samples in sqr
		reduce<<<redGRID, redBLOCK, size / redGRID.x * sizeof(double)>>>(d_err[i], tmp, size);
		cudaDeviceSynchronize();
		std::cout << "HERE" << std::endl;
	} // end for

	cudaMemcpy(err.data(), d_err, e_size * sizeof(double), cudaMemcpyDeviceToHost);

	cudaFree(d_err);
	cudaFree(d_sqr);
	cudaFree(d_x);
	cudaFree(d_y);

	return err;
} // end mseGPU

__global__ void crossEntropyTerm(double *logLoss, double *x, double *y, int len)
{
	int g_idx = gridDim.x * blockDim.x * (blockDim.y * blockIdx.y + threadIdx.y)
		+ blockDim.x * blockIdx.x + threadIdx.x;
	// first line finds number of threads in rows of grid above thread's row 
	// second line finds how far into row thread is
	// so it puts matrix of threads into row major form
	// note that if we have 1d vect of threads, this reduces to threadIdx.x

	// abort if extra thread in block
	if (g_idx >= len)
		return;

	// get array of log losses
	logLoss[g_idx] = y[g_idx] * log(x[g_idx]);

} // end crossEntropy

std::vector<double> crossEntropyGPU(double *x, double *y, int size, int e_size)
{
	double *tmp;
	double *d_err, *d_term, *d_x, *d_y;
	std::vector<double> err(e_size);

	cudaMalloc((void **) &d_err, e_size * sizeof(double));
	cudaMalloc((void **) &d_term, size * e_size * sizeof(double));
	cudaMalloc((void **) &d_x, size * e_size * sizeof(double));
	cudaMalloc((void **) &d_y, size * e_size * sizeof(double));

	cudaMemcpy(d_x, x, size * sizeof(double), cudaMemcpyHostToDevice);
	cudaMemcpy(d_y, y, size * sizeof(double), cudaMemcpyHostToDevice);

	dim3 trmGRID(size * e_size / 512 + 1);
	dim3 trmBLOCK(512);

	dim3 redGRID(size / 512 + 1);
	dim3 redBLOCK(512);

	crossEntropyTerm<<<trmGRID, trmBLOCK, 0>>>(d_term, d_x, d_y, size * e_size);
	
	for (int i = 0; i < e_size; i++)
	{
		tmp = d_term + i * size; // it will move through each samples in sqr
		reduce<<<redGRID, redBLOCK, size / redGRID.x>>>(d_err[i], tmp, size);
		cudaDeviceSynchronize();
	} // end for

	cudaMemcpy(err.data(), d_err, e_size * sizeof(double), cudaMemcpyDeviceToHost);

	cudaFree(d_err);
	cudaFree(d_term);
	cudaFree(d_x);
	cudaFree(d_y);

	return err;
}

