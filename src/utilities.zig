pub fn zero_array(array: []f64) void {
    for (array) |*elem| {
        elem.* = 0;
    }
}
