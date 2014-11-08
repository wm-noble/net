
from libc.stdlib cimport malloc, realloc, free
from libc.math cimport log, sqrt
from cython cimport boundscheck
from cython.parallel cimport prange
from cpython.ref cimport PyObject, Py_INCREF, Py_DECREF, Py_XDECREF
cimport numpy as np 
from numpy.random import normal
from struct import pack, unpack

cdef extern from 'stdint.h':
    ctypedef unsigned long long uint64_t

cdef extern from 'cfns.h':
    ctypedef double (*nodefn)(double) nogil
    extern double _sig(double) nogil
    extern double _bin(double) nogil

# Builtin action potential functions
def sig(double t):
    """Returns the value of the logistic curve evaluated at t."""
    return _sig(t)
def bin(double t):
    """Returns 1 if t > 0, else 0."""
    return _bin(t)

# Builtin cost functions
@boundscheck(False)
def quad_cost(np.ndarray[double] a, np.ndarray[double] e):
    """Returns the quadratic cost between two vectors."""
    if a.size != e.size:
        raise ValueError('Vectors must have the same dimension.')
    cdef double r = 0.0, d
    cdef uint64_t s = <uint64_t>a.size, i
    for i in range(s):
        d = a[i] - e[i]
        r += d * d
    return r / 2.0
@boundscheck(False)
def cent_cost(np.ndarray[double] a, np.ndarray[double] e):
    """Returns the cross-entropy cost between two vectors."""
    if a.size != e.size:
        raise ValueError('Vectors must have the same dimension.')
    cdef double r = 0.0
    cdef uint64_t s = <uint64_t>a.size, i
    for i in range(s):
        r -= e[i] * log(a[i]) + (1.0 - e[i]) * log(1.0 - a[i])
    return r

# For looking up built-in action potential functions by name
cdef nodefn cfns(str name):
    if name == 'sig':
        return &_sig
    if name == 'bin':
        return &_bin
    return NULL
# For looking up built-in action potential function names by function pointer
cdef str re_cfns(nodefn fn):
    if fn == &_sig:
        return 'sig'
    if fn == &_bin:
        return 'bin'
    return None

cdef class Node:
    """The basic element of a Network."""

    cdef double pot[2]                # Potential values at clock low and high
    cdef object pfn                   # Custom APF
    cdef double (*cfn)(double) nogil  # Built-in APF
    cdef bint is_neuron               # Whether to perform backpropagation

    property fn:
        "The action potential function of the node.\n"
        "Built-in APFs are represented by their name as a string. Custom APFs must be callable Python objects.\n"
        "Functions must take a single numerical argument and return a numerical result."
        def __get__(self):
            if self.cfn != NULL:
                return re_cfns(self.cfn)
            return self.pfn
        def __set__(self, object x):
            if x is None:
                self.pfn = None
                self.cfn = NULL
            elif isinstance(x, basestring):
                self.pfn = None
                self.cfn = cfns(str(x))
                if self.cfn == NULL:
                    raise ValueError('APF \'%s\' not a valid built-in function.' % str(x))
            elif callable(x):
                self.pfn = x
                self.cfn = NULL
            else:
                raise TypeError('Expects fn to be callable or a string.')
        def __del__(self):
            self.pfn = None
            self.cfn = NULL

    def __init__(self, double value=0.0, object fn=None):
        """Create a new Node object.

        Keyword arguments:
        value -- A constant potential value.
        fn -- The APF; Node outputs fn(value) if fn is not None else (value).
        """
        self.pot[0] = value
        self.pot[1] = value
        self.fn = fn

    # TODO: Make this better?
    def __call__(self, clock=None):
        if clock is None:
            return (self.pot[0] + self.pot[1]) / 2.0
        elif isinstance(clock, int):
            if clock == 0 or clock == 1:
                return self.pot[clock]
            else:
                raise ValueError('clock must be 0 or 1.')
        else:
            raise TypeError('clock must be 0 or 1.')

    # For convenience: maps a Node's input to it's output through it's APF.
    cdef void _update_set(self, bint clock, double pot) nogil:
        if self.pfn is not None:
            with gil:
                pot = <double>self.pfn(pot)
        elif self.cfn != NULL:
            pot = self.cfn(pot)
        self.pot[not clock] = pot

    cdef void _update(self, bint clock) nogil:
        self._update_set(clock, self.pot[clock])

    # The depth of the node from the input layer. By default, Node is considered an input.
    cdef uint64_t depth(self, Path *path, int *err) nogil:
        return 0

    def __str__(self):
        return 'Node'

    def __repr__(self):
        return str(self)

cdef class Input(Node):
    """A Node designed to quickly read data from an input numpy array."""

    cdef double[:] data    # The input vector
    cdef uint64_t i, size  # Current index and max index
    cdef bint loop         # Whether to loop when i >= size

    def __init__(self, double[:] data=None, object fn=None, double value=0.0, bint loop=0):
        """Create a new Input object for feeding numerical data into a network.

        Keyword arguments:
        data -- The data vector; data is read sequentially from the vector at each update. Default is None.
        fn -- The APF; Input outputs fn(data) if fn is not None else (data). Default is None.
        value -- The initial potential of the node before any data is read. Default is zero.
        loop -- Whether to read data cyclically and continuously. By default, potential becomes zero when there is no more data.
        """
        self.pot[0] = value
        self.pot[1] = value
        self.fn = fn
        self.loop = loop
        if data.size > 0:
            self.size = data.size
            self.data = data

    @boundscheck(False)
    cdef void _update(self, bint clock) nogil:
        if self.data is not None:
            self._update_set(clock, self.data[self.i])
            self.i += 1
            if self.i >= self.size:
                if self.loop:
                    self.i %= 0
                else:
                    self.data = None
        else:
            self._update_set(clock, 0.0)

    def __str__(self):
        return 'Input'

    @classmethod
    def Layer(self, double[:,:] data=None, object fn=None, double value=0.0, bint loop=0):
        """Returns a list of Input objects, each of which reads data from the corresponding column of a data matrix.

        Keyword arguments:
        data -- The data matrix; data is read sequentially down the rows at each update. Default is None.
        fn -- The APF for each node; Input outputs fn(data) if fn is not None else (data). Default is None.
        value -- The initial potential of each node before any data is read. Default is zero.
        loop -- Whether each node reads data cyclically and continuously. By default, potential becomes zero when there is no more data.
        """
        cols = data.shape[1]
        return [self(data=data[:,i], fn=fn, value=value, loop=loop) for i in range(cols)]

# Represents a parent (input) to a neuron.
cdef struct Parent:
    double weight   # The synaptic weight.
    PyObject *node  # The parent object.

# Linked list for tracing depth and feed-forwardness.
cdef struct Path:
    PyObject *child  # The Node object at this point in the path.
    Path *nxt

cdef class Neuron(Node):
    """A Node designed to process input from other nodes and perform backpropagation."""

    cdef public double bias  # The node bias.
    cdef Parent *parents     # Array of parents.
    cdef uint64_t c          # Number of parents.
    cdef double *dCdp        # For backpropagation.

    def __init__(self, double bias=0.0, dict parents=None, object fn='sig', double value=0.0):
        """Create a new Neuron object for processing data in a network.

        Keyword arguments:
        bias -- The node bias; Neuron value is (w * x + b) where w is synaptic weight, x is input and b is bias. Default is zero.
        parents -- Dictionary of the form {parent: weight} where parent is a Node object and weight is the associated synaptic weight. Default is None.
        fn -- The APF; Neuron outputs fn(value) if fn is not None else (value). Default is the logistic curve.
        value -- The initial potential of the node before any data is processed. Default is zero.
        """
        self.is_neuron = 1
        self.pot[0] = value
        self.pot[1] = value
        self.fn = fn
        self.bias = bias
        self.connect(parents)

    def __dealloc__(self):
        cdef uint64_t i
        for i in range(self.c):
            Py_DECREF(<object>self.parents[i].node)
        free(self.parents)

    def __len__(self):
        """Returns the number of parents."""
        return self.c

    def __getitem__(self, object x):
        """Returns self's weight for x. Unconnected nodes are considered to have zero weight."""
        cdef uint64_t i = self.index(<PyObject*>x)
        return self.parents[i].weight if i < self.c else 0.0

    # TODO: See if compound assignment covers this behavior already.
    def __setitem__(self, object x, double y):
        """Adds y to self's weight for x. Unconnected nodes as considered to have zero weight."""
        if not isinstance(x, Node):
            raise TypeError('Parent must be a Node.')
        cdef uint64_t i = self.index(<PyObject*>x)
        if i < self.c:
            self.parents[i].weight += y
        else:
            self.c += 1
            self.parents = <Parent*>realloc(self.parents, self.c * sizeof(Parent))
            if self.parents == NULL:
                self.c = 0
                raise MemoryError('Not enough memory to reallocate self.parents.')
            self.parents[i].node = <PyObject*>x
            Py_INCREF(x)
            self.parents[i].weight = y


    def __delitem__(self, object x):
        """Disconnects self from x."""
        cdef uint64_t i = self.index(<PyObject*>x), j
        if i < self.c:
            Py_DECREF(<object>self.parents[i].node)
            self.c -= 1
            for j in range(i, self.c):
                self.parents[j] = self.parents[j + 1]
            self.parents = <Parent*>realloc(self.parents, self.c * sizeof(Parent))
            if self.parents == NULL:
                self.c = 0
                raise MemoryError('Not enough memory to reallocate parents.')

    def __contains__(self, object x):
        """Returns True is x is connected to self."""
        return self.index(<PyObject*>x) < self.c

    # For convenience: Returns the index of node in parents else self.c.
    cdef uint64_t index(self, PyObject *node):
        cdef uint64_t i
        for i in range(self.c):
            if self.parents[i].node == node:
                return i
        return self.c

    def connect(self, dict parents=None):
        """Connects a mapping of {node: weight} parents to self."""
        cdef uint64_t l, i
        if parents is not None:
            l = <uint64_t>len(parents)
            if l > 0:
                self.c += l
                self.parents = <Parent*>realloc(self.parents, self.c * sizeof(Parent))
                if self.parents == NULL:
                    self.c = 0
                    raise MemoryError('Not enough memory to reallocate parents.')
                for (key, value) in parents.items():
                    if not isinstance(key, Node):
                        l = self.c - l
                        for i in range(l, self.c):
                            Py_DECREF(<object>self.parents[i].node)
                        self.c = l
                        self.parents = <Parent*>realloc(self.parents, self.c * sizeof(Parent))
                        raise TypeError('All keys of parents must be Nodes.')
                    l -= 1
                    self.parents[l].node = <PyObject*>key
                    Py_INCREF(key)
                    self.parents[l].weight = <double>value

    cdef void _update(self, bint clock) nogil:
        cdef double pot = self.bias
        cdef uint64_t i
        for i in range(self.c):
            pot += (<Node>self.parents[i].node).pot[clock] * self.parents[i].weight
        self._update_set(clock, pot)

    # Calculates the depth of the neuron from the input layer. Sets err nonzero is a feedback loop is found.
    cdef uint64_t depth(self, Path *path, int *err) nogil:
        cdef uint64_t i, tmp, r = 0
        cdef Path *newp = path
        while newp != NULL:
            if newp.child == <PyObject*>self:
                err[0] = -1
                return 0
            newp = newp.nxt
        newp = <Path*>malloc(sizeof(Path))
        if newp == NULL:
            err[0] = -2
            return 0
        newp.child = <PyObject*>self
        newp.nxt = path
        for i in range(self.c):
            tmp = (<Node>self.parents[i].node).depth(newp, err)
            if err[0] != 0:
                break
            if tmp > r:
                r = tmp
        free(newp)
        return r + 1

    cdef int _init_backprop(self) except -1:
        self.dCdp = <double*>malloc((self.c + 1) * sizeof(double))
        if self.dCdp == NULL:
            raise MemoryError('Not enough memory to allocate self.dCdp.')
        cdef uint64_t i, j = self.c + 1
        for i in range(j):
            self.dCdp[i] = 0.0
        return 0

    cdef void _backprop(self, double front, bint clock) nogil:
        front *= self.pot[clock] * (1.0 - self.pot[clock])
        self.dCdp[0] += front  # dCdb
        cdef uint64_t i
        for i in prange(self.c):
            self.dCdp[i + 1] += (<Node>self.parents[i].node).pot[clock] * front
            if (<Node>self.parents[i].node).is_neuron:
                (<Neuron>self.parents[i].node)._backprop(self.parents[i].weight * front, clock)

    cdef void _register_backprop(self, double alpha, double lamb) nogil:
        self.bias -= alpha * self.dCdp[0]
        self.dCdp[0] = 0.0
        cdef uint64_t i
        for i in range(self.c):
            self.parents[i].weight -= alpha * (self.dCdp[i + 1] + lamb * self.parents[i].weight)
            self.dCdp[i + 1] = 0.0

    cdef void _dealloc_backprop(self) nogil:
        free(self.dCdp)

    def __str__(self):
        return 'Neuron(degree=%d, bias=%f)' % (self.c, self.bias)

cdef list a_to_l(PyObject **a, uint64_t c):
    cdef uint64_t i
    return [<object>a[i] for i in range(c)]
cdef PyObject **l_to_a(list l, uint64_t *c_out, PyObject **prev, uint64_t prevc) except NULL:
    c_out[0] = <uint64_t>len(l)
    cdef uint64_t i
    for i in range(prevc):
        Py_XDECREF(prev[i])
    prev = <PyObject**>realloc(prev, c_out[0] * sizeof(PyObject*))
    if prev == NULL:
        raise MemoryError('Not enough memory to reallocate array of Python objects.')
    cdef uint64_t j = 0
    for e in l:
        if not isinstance(e, Node):
            for i in range(j):
                Py_XDECREF(prev[i])
            free(prev)
            raise TypeError('All nodes of a network must be Nodes.')
        prev[j] = <PyObject*>e
        Py_INCREF(e)
        j += 1
    return prev
cdef void free_a(PyObject **a, uint64_t c):
    cdef uint64_t i
    for i in range(c):
        Py_XDECREF(a[i])
    free(a)

cdef class Network:

    cdef PyObject **_nodes
    cdef uint64_t c
    cdef bint clock
    cdef PyObject **_output
    cdef uint64_t oc
    cdef uint64_t layers

    property nodes:
        def __get__(self):
            return a_to_l(self._nodes, self.c)
        def __set__(self, list x):
            self._nodes = l_to_a(x, &self.c, self._nodes, self.c)
        def __del__(self):
            free_a(self._nodes, self.c)
            self._nodes = NULL
            self.c = 0
    property output:
        def __get__(self):
            return a_to_l(self._output, self.oc)
        def __set__(self, list x):
            self._output = l_to_a(x, &self.oc, self._output, self.oc)
        def __del__(self):
            free_a(self._output, self.oc)
            self._output = NULL
            self.oc = 0

    def __cinit__(self, list nodes=None, list output=None, bint clock=0):
        self.clock = clock

    def __init__(self, list nodes=None, list output=None, bint clock=0):
        if nodes is not None:
            self.nodes = nodes
        if output is not None:
            self.output = output

    def __dealloc__(self):
        free_a(self._nodes, self.c)
        free_a(self._output, self.oc)

    cdef double *_update_once(self, PyObject **output, uint64_t oc) except? NULL:
        cdef double *r = NULL
        cdef uint64_t i
        for i in prange(self.c, nogil=True):
            (<Node>self._nodes[i])._update(self.clock)
        self.clock = not self.clock
        if output != NULL:
            r = <double*>malloc(oc * sizeof(double))
            if r == NULL:
                raise MemoryError('Not enough memory to reallocate parents.')
            else:
                for i in range(oc):
                    r[i] = (<Node>output[i]).pot[self.clock]
        return r

    def update(self, object output=None, uint64_t times=1):
        cdef PyObject **_output
        cdef uint64_t oc
        if output is None:
            _output = self._output
            oc = self.oc
        else:
            _output = l_to_a(output, &oc, NULL, 0)
        cdef np.ndarray[double, ndim=2] r = np.ndarray(shape=(times, oc))
        cdef uint64_t i, j
        cdef double *buff
        for i in range(times):
            buff = self._update_once(_output, oc)
            for j in range(oc):
                r[i][j] = buff[j]
            free(buff)
        if _output != self._output:
            free_a(_output, oc)
        return r

    def depth(self):
        if self._output == NULL:
            raise ValueError('Network is not feed-forward.')
        cdef uint64_t depth = 0, i, tmp
        cdef int err = 0
        for i in range(self.oc):
            tmp = (<Node>self._output[i]).depth(NULL, &err)
            if err == -1:
                raise ValueError('Network is not feed-forward.')
            if err == -2:
                raise MemoryError('Not enough memory to allocate search path.')
            if tmp > depth:
                depth = tmp
        return depth

    def backprop(self, np.ndarray[double, ndim=2] expect, uint64_t batch=1, double alpha=0.5, double lamb=0.1, uint64_t depth=0):
        if depth == 0:
            print('Calculating depth of network ='),
            depth = <uint64_t>self.depth()
            print('%d' % depth)
        cdef uint64_t i, j, k
        if depth > 0:
            print('Pre-running ...'),
            for i in range(depth):
                self._update_once(NULL, 0)
            print('Done')
        print('Setting up backpropagation buffers ...'),
        for i in range(self.c):
            if (<Node>self._nodes[i]).is_neuron:
                try:
                    (<Neuron>self._nodes[i])._init_backprop()
                except:
                    for j in range(i):
                        if (<Node>self._nodes[j]).is_neuron:
                            (<Neuron>self._nodes[j])._dealloc_backprop()
                    raise
        print('Done')
        alpha /= <double>batch
        cdef uint64_t l = expect.size / (self.oc * batch)
        print('Running [%d] {' % l)
        cdef double cost, c
        for i in range(l):
            cost = 0.0
            for j in range(batch):
                self._update_once(NULL, 0)
                for k in range(self.oc):
                    c = (<Node>self._output[k]).pot[self.clock] - expect[i][k]
                    if (<Node>self._output[k]).is_neuron:
                        with nogil:
                            (<Neuron>self._output[k])._backprop(c, self.clock)
                    cost += c * c
            print('\tBatch [%d] Cost = %f' % (batch, cost / (2.0 * batch)))
            for k in prange(self.c, nogil=True):
                if (<Node>self._nodes[k]).is_neuron:
                    (<Neuron>self._nodes[k])._register_backprop(alpha, lamb)
        print('} Done')
        print('Freeing backpropagation buffers ...'),
        for i in prange(self.c, nogil=True):
            if (<Node>self._nodes[i]).is_neuron:
                (<Neuron>self._nodes[i])._dealloc_backprop()
        print('Done')

    def write(self, filename):
        f = open(filename, 'wb')
        f.write(pack('!Q', self.c))
        for i in range(self.c):
            if isinstance(<object>self._nodes[i], Neuron):
                f.write((<Neuron>self._nodes[i]).write_data(self.index))
            elif isinstance(<object>self._nodes[i], Input):
                f.write((<Input>self._nodes[i]).write_data(self.index))
            elif isinstance(<object>self._nodes[i], Node):
                f.write((<Node>self._nodes[i]).write_data(self.index))
        f.close()
    #Node
    cdef str write_data(self, ifn=None):
        fn_name = re_cfns(self.cfn)
        if fn_name is None:
            fn_name = ''
        return pack('!B3sdd', 0, fn_name, self.pot[0], self.pot[1])
        #INPUT
    cdef str write_data(self, ifn=None):
        fn_name = re_cfns(self.cfn)
        if fn_name is None:
            fn_name = ''
        return pack('!B3sddB', 1, fn_name, self.pot[0], self.pot[1], self.loop)
#neuron
    cdef str write_data(self, ifn=None):
        fn_name = re_cfns(self.cfn)
        if fn_name is None:
            fn_name = ''
        r = pack('!B3sdddQ', 2, fn_name, self.pot[0], self.pot[1], self.bias, self.c)
        cdef uint64_t i
        for i in range(self.c):
            r += pack('!Qd', ifn(<object>self.parents[i].node), self.parents[i].weight)
        return r

    def index(self, object node):
        """Returns the index of node in _nodes else self.c."""
        cdef uint64_t i
        for i in range(self.c):
            if self._nodes[i] == <PyObject*>node:
                return i
        return self.c

    @classmethod
    def open(self, filename): # TODO: write
        f = open(filename, 'rb')
        c, = unpack('!Q', f.read(8))
        for i in range(c):
            t, = unpack('!B', f.read(1))
            if t == 2:    # Neuron
                pass
            elif t == 1:  # Input
                pass
            else:         # Node
                pass
        #return Network(nodes=nodes, output=output, clock=clock)
        return None
    #Node
    cdef int read_data(self, data, ifn=None) except -1:
        fn_name, pot0, pot1 = unpack('!3sdd', data)
        self.fn = fn_name
        self.pot[0] = <double>pot0
        self.pot[1] = <double>pot1
        #INPUT
    cdef int read_data(self, data, ifn=None) except -1:
        fn_name, pot0, pot1, loop = unpack('!3sddB', data)
        self.fn = fn_name
        self.pot[0] = <double>pot0
        self.pot[1] = <double>pot1
        self.loop = <bint>loop
#neuron
    cdef int read_data(self, data, ifn=None) except -1:
        fn_name, pot0, pot1, bias, c = unpack('!3sdddQ', data[:35])
        self.fn = fn_name
        self.pot[0] = <double>pot0
        self.pot[1] = <double>pot1
        self.bias = <double>bias
        self.c = <uint64_t>c
        self.parents = <Parent*>malloc(self.c * sizeof(Parent))
        if self.parents == NULL:
            self.c = 0
            raise MemoryError('Not enough memory to allocate parents.')
        cdef uint64_t i
        for i in range(self.c):
            try:
                n, b = unpack('!Qd', data[(35+16*i):(51+16*i)])
            except:
                free(self.parents)
                self.c = 0
                raise
            self.parents[i].node.i = <uint64_t>n
            self.parents[i].weight = <double>b
        return 0

    def __str__(self):
        cdef uint64_t i
        r = 'Network {\n'
        for i in range(self.c):
            r += '    ' + str(<object>self._nodes[i]) + '\n'
        return r + '}'

    def __repr__(self):
        return str(self)

    @classmethod
    def Layered(self, object layers, double[:,:] data):
        nodes = Input.Layer(data=data)
        last_w = len(nodes)
        if last_w == 0:
            raise ValueError('Input data must not be empty.')
        for w in layers:
            if w <= 0:
                raise ValueError('Layer width must be positive.')
            nodes.extend([Neuron(bias=normal(), parents={n: normal(0.0, 1.0/sqrt(last_w)) for n in nodes[-last_w:]}, fn='sig') for i in range(w)])
            last_w = w
        return self(nodes=nodes, output=nodes[-last_w:])

