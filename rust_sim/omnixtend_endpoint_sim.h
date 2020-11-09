#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

typedef struct SimInfo SimInfo;

typedef struct Socket Socket;

/**
 * Calculate the number of bytes in the last error's error message **not**
 * including any trailing `null` characters.
 */
int sim_last_error_length(void);

/**
 * Write the most recent error message into a caller-provided buffer as a UTF-8
 * string, returning the number of bytes written.
 *
 * # Note
 *
 * This writes a **UTF-8** string into the buffer. Windows users may need to
 * convert it to a UTF-16 "unicode" afterwards.
 *
 * If there are no recent errors then this returns `0` (because we wrote 0
 * bytes). `-1` is returned if there are any errors, for example when passed a
 * null pointer or a buffer of insufficient size.
 */
int sim_last_error_message(char *buffer, int length);

void sim_init_logging(void);

const struct SimInfo *sim_new(uintptr_t number, bool compat_mode);

void sim_destroy(const struct SimInfo *t);

void sim_next_flit(uint64_t (*r)[3], struct SimInfo *t);

void sim_push_flit(const struct SimInfo *t, uint64_t val, bool last, uint8_t mask);

void sim_tick(const struct SimInfo *t);

void sim_print_reg(uint64_t name, uint64_t value);

void start_execution_thread(struct SimInfo *t);

void stop_execution_thread(struct SimInfo *t);

bool can_destroy_execution_thread(struct SimInfo *t);

void destroy_execution_thread(struct SimInfo *t);

const struct Socket *socket_new(const int8_t *opt);

void socket_destroy(const struct Socket *t);

bool socket_active(const struct Socket *t);

void socket_next_flit(uint64_t (*r)[4], const struct Socket *t);

void socket_push_flit(const struct Socket *t, uint64_t val, bool last, uint8_t mask);
