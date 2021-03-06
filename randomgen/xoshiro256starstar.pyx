from libc.stdlib cimport malloc, free
from cpython.pycapsule cimport PyCapsule_New

import numpy as np
cimport numpy as np

try:
    from threading import Lock
except ImportError:
    from dummy_threading import Lock

from randomgen.common cimport *
from randomgen.distributions cimport brng_t
from randomgen.entropy import random_entropy, seed_by_array

np.import_array()

cdef extern from "src/xoshiro256starstar/xoshiro256starstar.h":

    struct s_xoshiro256starstar_state:
        uint64_t s[4]
        int has_uint32
        uint32_t uinteger

    ctypedef s_xoshiro256starstar_state xoshiro256starstar_state

    uint64_t xoshiro256starstar_next64(xoshiro256starstar_state *state)  nogil
    uint32_t xoshiro256starstar_next32(xoshiro256starstar_state *state)  nogil
    void xoshiro256starstar_jump(xoshiro256starstar_state *state)

cdef uint64_t xoshiro256starstar_uint64(void* st) nogil:
    return xoshiro256starstar_next64(<xoshiro256starstar_state *>st)

cdef uint32_t xoshiro256starstar_uint32(void *st) nogil:
    return xoshiro256starstar_next32(<xoshiro256starstar_state *> st)

cdef double xoshiro256starstar_double(void* st) nogil:
    return uint64_to_double(xoshiro256starstar_next64(<xoshiro256starstar_state *>st))

cdef class Xoshiro256StarStar:
    """
    Xoshiro256StarStar(seed=None)

    Container for the xoshiro256** pseudo-random number generator.

    Parameters
    ----------
    seed : {None, int, array_like}, optional
        Random seed initializing the pseudo-random number generator.
        Can be an integer in [0, 2**64-1], array of integers in
        [0, 2**64-1] or ``None`` (the default). If `seed` is ``None``,
        then ``Xoshiro256StarStar`` will try to read data from
        ``/dev/urandom`` (or the Windows analog) if available.  If
        unavailable, a 64-bit hash of the time and process ID is used.

    Notes
    -----
    xoshiro256** is written by David Blackman and Sebastiano Vigna.
    It is a 64-bit PRNG that uses a carefully linear transformation.
    This produces a fast PRNG with excellent statistical quality
    [1]_. xoshiro256** has a period of :math:`2^{256} - 1`
    and supports jumping the sequence in increments of :math:`2^{128}`,
    which allows multiple non-overlapping sequences to be generated.

    ``Xoshiro256StarStar`` exposes no user-facing API except ``generator``,
    ``state``, ``cffi`` and ``ctypes``. Designed for use in a
    ``RandomGenerator`` object.

    **Compatibility Guarantee**

    ``Xoshiro256StarStar`` guarantees that a fixed seed will always produce the
    same results.

    See ``Xorshift1024`` for a related PRNG with different periods
    (:math:`2^{1024} - 1`) and jump size (:math:`2^{512} - 1`).

    **Parallel Features**

    ``Xoshiro256StarStar`` can be used in parallel applications by
    calling the method ``jump`` which advances the state as-if
    :math:`2^{128}` random numbers have been generated. This
    allow the original sequence to be split so that distinct segments can be used
    in each worker process. All generators should be initialized with the same
    seed to ensure that the segments come from the same sequence.

    >>> from randomgen import RandomGenerator, Xoshiro256StarStar
    >>> rg = [RandomGenerator(Xoshiro256StarStar(1234)) for _ in range(10)]
    # Advance each Xoshiro256StarStar instance by i jumps
    >>> for i in range(10):
    ...     rg[i].brng.jump(i)

    **State and Seeding**

    The ``Xoshiro256StarStar`` state vector consists of a 4 element array
    of 64-bit unsigned integers.

    ``Xoshiro256StarStar`` is seeded using either a single 64-bit unsigned
    integer or a vector of 64-bit unsigned integers.  In either case, the
    input seed is used as an input (or inputs) for another simple random
    number generator, Splitmix64, and the output of this PRNG function is
    used as the initial state. Using a single 64-bit value for the seed can
    only initialize a small range of the possible initial state values.  When
    using an array, the SplitMix64 state for producing the ith component of
    the initial state is XORd with the ith value of the seed array until the
    seed array is exhausted. When using an array the initial state for the
    SplitMix64 state is 0 so that using a single element array and using the
    same value as a scalar will produce the same initial state.

    Examples
    --------
    >>> from randomgen import RandomGenerator, Xoshiro256StarStar
    >>> rg = RandomGenerator(Xoshiro256StarStar(1234))
    >>> rg.standard_normal()
    0.123  # random

    Identical method using only Xoshiro256StarStar

    >>> rg = Xoshiro256StarStar(1234).generator
    >>> rg.standard_normal()
    0.123  # random

    References
    ----------
    .. [1] "xoroshiro+ / xorshift* / xorshift+ generators and the PRNG shootout",
           http://xorshift.di.unimi.it/
    """
    cdef xoshiro256starstar_state *rng_state
    cdef brng_t *_brng
    cdef public object capsule
    cdef object _ctypes
    cdef object _cffi
    cdef object _generator
    cdef public object lock

    def __init__(self, seed=None):
        self.rng_state = <xoshiro256starstar_state *>malloc(sizeof(xoshiro256starstar_state))
        self._brng = <brng_t *>malloc(sizeof(brng_t))
        self.seed(seed)
        self.lock = Lock()

        self._brng.state = <void *>self.rng_state
        self._brng.next_uint64 = &xoshiro256starstar_uint64
        self._brng.next_uint32 = &xoshiro256starstar_uint32
        self._brng.next_double = &xoshiro256starstar_double
        self._brng.next_raw = &xoshiro256starstar_uint64

        self._ctypes = None
        self._cffi = None
        self._generator = None

        cdef const char *name = "BasicRNG"
        self.capsule = PyCapsule_New(<void *>self._brng, name, NULL)

    # Pickling support:
    def __getstate__(self):
        return self.state

    def __setstate__(self, state):
        self.state = state

    def __reduce__(self):
        from randomgen._pickle import __brng_ctor
        return __brng_ctor, (self.state['brng'],), self.state

    def __dealloc__(self):
        if self.rng_state:
            free(self.rng_state)
        if self._brng:
            free(self._brng)

    cdef _reset_state_variables(self):
        self.rng_state.has_uint32 = 0
        self.rng_state.uinteger = 0

    def random_raw(self, size=None, output=True):
        """
        random_raw(self, size=None)

        Return randoms as generated by the underlying BasicRNG

        Parameters
        ----------
        size : int or tuple of ints, optional
            Output shape.  If the given shape is, e.g., ``(m, n, k)``, then
            ``m * n * k`` samples are drawn.  Default is None, in which case a
            single value is returned.
        output : bool, optional
            Output values.  Used for performance testing since the generated
            values are not returned.

        Returns
        -------
        out : uint or ndarray
            Drawn samples.

        Notes
        -----
        This method directly exposes the the raw underlying pseudo-random
        number generator. All values are returned as unsigned 64-bit
        values irrespective of the number of bits produced by the PRNG.

        See the class docstring for the number of bits returned.
        """
        return random_raw(self._brng, self.lock, size, output)

    def _benchmark(self, Py_ssize_t cnt, method=u'uint64'):
        return benchmark(self._brng, self.lock, cnt, method)

    def seed(self, seed=None):
        """
        seed(seed=None)

        Seed the generator.

        This method is called at initialized. It can be called again to
        re-seed the generator.

        Parameters
        ----------
        seed : {int, ndarray}, optional
            Seed for PRNG. Can be a single 64 bit unsigned integer or an array
            of 64 bit unsigned integers.

        Raises
        ------
        ValueError
            If seed values are out of range for the PRNG.
        """
        ub = 2 ** 64
        if seed is None:
            try:
                state = random_entropy(8)
            except RuntimeError:
                state = random_entropy(8, 'fallback')
            state = state.view(np.uint64)
        else:
            state = seed_by_array(seed, 4)
        self.rng_state.s[0] = <uint64_t>int(state[0])
        self.rng_state.s[1] = <uint64_t>int(state[1])
        self.rng_state.s[2] = <uint64_t>int(state[2])
        self.rng_state.s[3] = <uint64_t>int(state[3])
        self._reset_state_variables()

    def jump(self, np.npy_intp iter=1):
        """
        jump(iter=1)

        Jumps the state as-if 2**128 random numbers have been generated.

        Parameters
        ----------
        iter : integer, positive
            Number of times to jump the state of the rng.

        Returns
        -------
        self : Xoshiro256StarStar
            PRNG jumped iter times

        Notes
        -----
        Jumping the rng state resets any pre-computed random numbers. This is required
        to ensure exact reproducibility.
        """
        cdef np.npy_intp i
        for i in range(iter):
            xoshiro256starstar_jump(self.rng_state)
        self._reset_state_variables()
        return self

    @property
    def state(self):
        """
        Get or set the PRNG state

        Returns
        -------
        state : dict
            Dictionary containing the information required to describe the
            state of the PRNG
        """
        state = np.empty(4, dtype=np.uint64)
        state[0] = self.rng_state.s[0]
        state[1] = self.rng_state.s[1]
        state[2] = self.rng_state.s[2]
        state[3] = self.rng_state.s[3]
        return {'brng': self.__class__.__name__,
                's': state,
                'has_uint32': self.rng_state.has_uint32,
                'uinteger': self.rng_state.uinteger}

    @state.setter
    def state(self, value):
        if not isinstance(value, dict):
            raise TypeError('state must be a dict')
        brng = value.get('brng', '')
        if brng != self.__class__.__name__:
            raise ValueError('state must be for a {0} '
                             'PRNG'.format(self.__class__.__name__))
        self.rng_state.s[0] = <uint64_t>value['s'][0]
        self.rng_state.s[1] = <uint64_t>value['s'][1]
        self.rng_state.s[2] = <uint64_t>value['s'][2]
        self.rng_state.s[3] = <uint64_t>value['s'][3]
        self.rng_state.has_uint32 = value['has_uint32']
        self.rng_state.uinteger = value['uinteger']

    @property
    def ctypes(self):
        """
        ctypes interface

        Returns
        -------
        interface : namedtuple
            Named tuple containing ctypes wrapper

            * state_address - Memory address of the state struct
            * state - pointer to the state struct
            * next_uint64 - function pointer to produce 64 bit integers
            * next_uint32 - function pointer to produce 32 bit integers
            * next_double - function pointer to produce doubles
            * brng - pointer to the Basic RNG struct
        """
        if self._ctypes is None:
            self._ctypes = prepare_ctypes(self._brng)

        return self._ctypes

    @property
    def cffi(self):
        """
        CFFI interface

        Returns
        -------
        interface : namedtuple
            Named tuple containing CFFI wrapper

            * state_address - Memory address of the state struct
            * state - pointer to the state struct
            * next_uint64 - function pointer to produce 64 bit integers
            * next_uint32 - function pointer to produce 32 bit integers
            * next_double - function pointer to produce doubles
            * brng - pointer to the Basic RNG struct
        """
        if self._cffi is not None:
            return self._cffi
        self._cffi = prepare_cffi(self._brng)
        return self._cffi

    @property
    def generator(self):
        """
        Return a RandomGenerator object

        Returns
        -------
        gen : randomgen.generator.RandomGenerator
            Random generator used this instance as the basic RNG
        """
        if self._generator is None:
            from .generator import RandomGenerator
            self._generator = RandomGenerator(self)
        return self._generator
