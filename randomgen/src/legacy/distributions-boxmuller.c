#include "distributions-boxmuller.h"

static NPY_INLINE double legacy_double(aug_brng_t *aug_state) {
  return aug_state->basicrng->next_double(aug_state->basicrng->state);
}

double legacy_gauss(aug_brng_t *aug_state) {
  if (aug_state->has_gauss) {
    const double temp = aug_state->gauss;
    aug_state->has_gauss = false;
    aug_state->gauss = 0.0;
    return temp;
  } else {
    double f, x1, x2, r2;

    do {
      x1 = 2.0 * legacy_double(aug_state) - 1.0;
      x2 = 2.0 * legacy_double(aug_state) - 1.0;
      r2 = x1 * x1 + x2 * x2;
    } while (r2 >= 1.0 || r2 == 0.0);

    /* Polar method, a more efficient version of the Box-Muller approach. */
    f = sqrt(-2.0 * log(r2) / r2);
    /* Keep for next call */
    aug_state->gauss = f * x1;
    aug_state->has_gauss = true;
    return f * x2;
  }
}

double legacy_standard_exponential(aug_brng_t *aug_state) {
  /* We use -log(1-U) since U is [0, 1) */
  return -log(1.0 - legacy_double(aug_state));
}

double legacy_standard_gamma(aug_brng_t *aug_state, double shape) {
  double b, c;
  double U, V, X, Y;

  if (shape == 1.0) {
    return legacy_standard_exponential(aug_state);
  }
  else if (shape == 0.0) {
    return 0.0;
  } else if (shape < 1.0) {
    for (;;) {
      U = legacy_double(aug_state);
      V = legacy_standard_exponential(aug_state);
      if (U <= 1.0 - shape) {
        X = pow(U, 1. / shape);
        if (X <= V) {
          return X;
        }
      } else {
        Y = -log((1 - U) / shape);
        X = pow(1.0 - shape + shape * Y, 1. / shape);
        if (X <= (V + Y)) {
          return X;
        }
      }
    }
  } else {
    b = shape - 1. / 3.;
    c = 1. / sqrt(9 * b);
    for (;;) {
      do {
        X = legacy_gauss(aug_state);
        V = 1.0 + c * X;
      } while (V <= 0.0);

      V = V * V * V;
      U = legacy_double(aug_state);
      if (U < 1.0 - 0.0331 * (X * X) * (X * X))
        return (b * V);
      if (log(U) < 0.5 * X * X + b * (1. - V + log(V)))
        return (b * V);
    }
  }
}

double legacy_gamma(aug_brng_t *aug_state, double shape, double scale) {
  return scale * legacy_standard_gamma(aug_state, shape);
}

double legacy_pareto(aug_brng_t *aug_state, double a) {
  return exp(legacy_standard_exponential(aug_state) / a) - 1;
}

double legacy_weibull(aug_brng_t *aug_state, double a) {
  if (a == 0.0) {
    return 0.0;
  }
  return pow(legacy_standard_exponential(aug_state), 1. / a);
}

double legacy_power(aug_brng_t *aug_state, double a) {
  return pow(1 - exp(-legacy_standard_exponential(aug_state)), 1. / a);
}

double legacy_chisquare(aug_brng_t *aug_state, double df) {
  return 2.0 * legacy_standard_gamma(aug_state, df / 2.0);
}

double legacy_noncentral_chisquare(aug_brng_t *aug_state, double df,
                                   double nonc) {
  double out;
  if (nonc == 0) {
    return legacy_chisquare(aug_state, df);
  }
  if (1 < df) {
    const double Chi2 = legacy_chisquare(aug_state, df - 1);
    const double n = legacy_gauss(aug_state) + sqrt(nonc);
    return Chi2 + n * n;
  } else {
    const long i = random_poisson(aug_state->basicrng, nonc / 2.0);
    out = legacy_chisquare(aug_state, df + 2 * i);
    /* Insert nan guard here to avoid changing the stream */
    if (npy_isnan(nonc)){
      return NPY_NAN;
    } else {
    return out;
    }
  }
}

double legacy_noncentral_f(aug_brng_t *aug_state, double dfnum, double dfden,
                           double nonc) {
  double t = legacy_noncentral_chisquare(aug_state, dfnum, nonc) * dfden;
  return t / (legacy_chisquare(aug_state, dfden) * dfnum);
}

double legacy_wald(aug_brng_t *aug_state, double mean, double scale) {
  double U, X, Y;
  double mu_2l;

  mu_2l = mean / (2 * scale);
  Y = legacy_gauss(aug_state);
  Y = mean * Y * Y;
  X = mean + mu_2l * (Y - sqrt(4 * scale * Y + Y * Y));
  U = legacy_double(aug_state);
  if (U <= mean / (mean + X)) {
    return X;
  } else {
    return mean * mean / X;
  }
}

double legacy_normal(aug_brng_t *aug_state, double loc, double scale) {
  return loc + scale * legacy_gauss(aug_state);
}

double legacy_lognormal(aug_brng_t *aug_state, double mean, double sigma) {
  return exp(legacy_normal(aug_state, mean, sigma));
}

double legacy_standard_t(aug_brng_t *aug_state, double df) {
  double num, denom;

  num = legacy_gauss(aug_state);
  denom = legacy_standard_gamma(aug_state, df / 2);
  return sqrt(df / 2) * num / sqrt(denom);
}

int64_t legacy_negative_binomial(aug_brng_t *aug_state, double n, double p) {
  double Y = legacy_gamma(aug_state, n, (1 - p) / p);
  return random_poisson(aug_state->basicrng, Y);
}

double legacy_standard_cauchy(aug_brng_t *aug_state) {
  return legacy_gauss(aug_state) / legacy_gauss(aug_state);
}

double legacy_beta(aug_brng_t *aug_state, double a, double b) {
  double Ga, Gb;

  if ((a <= 1.0) && (b <= 1.0)) {
    double U, V, X, Y;
    /* Use Johnk's algorithm */

    while (1) {
      U = legacy_double(aug_state);
      V = legacy_double(aug_state);
      X = pow(U, 1.0 / a);
      Y = pow(V, 1.0 / b);

      if ((X + Y) <= 1.0) {
        if (X + Y > 0) {
          return X / (X + Y);
        } else {
          double logX = log(U) / a;
          double logY = log(V) / b;
          double logM = logX > logY ? logX : logY;
          logX -= logM;
          logY -= logM;

          return exp(logX - log(exp(logX) + exp(logY)));
        }
      }
    }
  } else {
    Ga = legacy_standard_gamma(aug_state, a);
    Gb = legacy_standard_gamma(aug_state, b);
    return Ga / (Ga + Gb);
  }
}

double legacy_f(aug_brng_t *aug_state, double dfnum, double dfden) {
  return ((legacy_chisquare(aug_state, dfnum) * dfden) /
          (legacy_chisquare(aug_state, dfden) * dfnum));
}

double legacy_exponential(aug_brng_t *aug_state, double scale) {
  return scale * legacy_standard_exponential(aug_state);
}
