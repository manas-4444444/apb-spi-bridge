// Minimal Verilator main for a timing-based testbench that also writes coverage.dat
#include "Vtb_apb_spi_random.h"
#include "verilated.h"
#include "verilated_cov.h"
int main(int argc, char** argv) {
    VerilatedContext* ctx = new VerilatedContext;
    ctx->commandArgs(argc, argv);
    Vtb_apb_spi_random* top = new Vtb_apb_spi_random{ctx};
    while (!ctx->gotFinish()) {
        top->eval();
        if (!top->eventsPending()) break;
        ctx->time(top->nextTimeSlot());
    }
    top->final();
    ctx->coveragep()->write("coverage.dat");
    delete top;
    delete ctx;
    return 0;
}
