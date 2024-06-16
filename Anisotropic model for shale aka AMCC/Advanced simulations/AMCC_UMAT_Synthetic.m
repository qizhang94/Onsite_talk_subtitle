function [STRESS, hsv, DDSDDE, DELAS, Cep]=AMCC_UMAT_Synthetic(PROPS, STRESS0, DSTRAIN0, hsv0) %#codegen

% Assume 2D plane strain
% STRESS0: Old 6*1, NON-ZERO! Otherwise, bulk modulus K would be zero!
% STRESS: New 6*1
% DDSDDE: Algorithmic consistent tangent operator
% hsv, hsv0: History variables such as the preconsolidation pressure p_c
% Cep is used for elastoplastic acoustic tensor Aep in shear band analysis


I2 = eye(3); % Second order identity tensor
I2_dyad_I2 = zeros(3,3,3,3);
I4 = zeros(3,3,3,3); % Fourth order identity tensor
D = zeros(3,3,3,3); % 偏应力deviatoric stress投影张量
P = zeros(3,3,3,3);
Ce = zeros(3,3,3,3); % 弹性刚度张量


theta = PROPS(4); % Bedding plane orientation

n = [-sin(theta); 0; cos(theta)]; % Bedding normal column vector
m = n*n';

c1p = 0.79;
c3p = 2*(1-c1p);
c2p = 0.87 - c1p - c3p; % 0.82 and 0.85 are tunable

for i = 1:3
    for j = 1:3
        for k = 1:3
            for l = 1:3
                I4(i, j, k, l) = (i==k)*(j==l);
                D(i, j, k, l) = I4(i, j, k, l) - 1/3*(i==j)*(k==l);
                I2_dyad_I2(i, j, k , l) = (i==j)*(k==l);
                P(i, j, k, l) = c1p*I4(i, j, k, l) + c2p*(m(i, k)*m(j, l)) ...
                    +(c3p/2)*(m(i, k)*(j==l) + (i==k)*m(j, l)); % c1p = 0.7, c2p = -0.36, c3p = 0.6
                Ce(i, j, k, l) = 5334.9*(i==j)*(k==l) + 2*6869.2*I4(i, j, k, l) ...
                    + (-400.3267)*((i==j)*m(k, l) + m(i, j)*(k==l)) + 1427.9*(m(i, j)*m(k, l)) ...
                    + 2*(6314.6 - 6869.2)*(m(i, k)*(j==l) + (i==k)*m(j, l)); % MPa
                % a = −1870 MPa, b = 5420 MPa, 𝜆 = 4270 MPa, 𝜇L = 6510 MPa, and 𝜇T = 9360 MPa
            end
        end
    end
end




I4 = reshape(I4, [9,9]);
I2 = reshape(I2, [9,1]);
P = reshape(P, [9,9]);
D = reshape(D, [9,9]);

a = 1/3*I2; % Better fit to experiment data, no projection tensor
A = 3*P*D*P;
Ce = reshape(Ce, [9,9]);

%% Extract material parameters from "PROPS"

M = PROPS(1); % Slope of CSL
lambda = PROPS(2);
kappa = PROPS(3);

lambdap = -(lambda - kappa); % Sign convention is different from traditional soil mechanics

%% Resize/reshape some variables
sigma_old = [STRESS0(1), STRESS0(4), STRESS0(5); STRESS0(4), STRESS0(2), STRESS0(6); STRESS0(5), STRESS0(6), STRESS0(3)]; % 3*3 MATRIX
strain_incr = [DSTRAIN0(1), DSTRAIN0(4)/2, DSTRAIN0(5)/2; DSTRAIN0(4)/2, DSTRAIN0(2), DSTRAIN0(6)/2; DSTRAIN0(5)/2, DSTRAIN0(6)/2, DSTRAIN0(3)]; % 3*3 MATRIX, "/2" for shear strain
sigma_trial = reshape(sigma_old, [9,1]) + Ce*reshape(strain_incr, [9,1]); % 9*1 VECTOR

%% Run 3D update (core part)
Pc_old = hsv0(1); % Negative number
hsv = hsv0; % Initialization for MEX function
YIELD_VALUE = sigma_trial'*A*sigma_trial/(2*M^2) + (a'*sigma_trial)*(a'*sigma_trial - Pc_old);

if YIELD_VALUE < 1E-12 % Elastic
    sigma_new = sigma_trial;
    Pc_new = Pc_old;
    ACTO = Ce;
    Cep = Ce; % for bifurcation analysis (material itself elastoplastic tangent) 9*9 matrix
    hsv(1) = Pc_new;
    hsv(2) = hsv0(2); % Equivalent plastic strain
else % Plastic
    J = zeros(11, 11);
    R = zeros(11, 1);
    
    sigma_iter = reshape(sigma_old, [9,1]); % In Newton iteration
    Dlambda_iter = 0;
    Pc_iter = Pc_old;

    % Initial residual
    R(1:9) = sigma_iter + Dlambda_iter*Ce*(A*sigma_iter/M/M + a*(2*a'*sigma_iter - Pc_iter)) - sigma_trial;
    r0 = norm(R) + 1; % Initial residual norm

    error_tol = 1e-12;
    k = 0; % 牛顿迭代次数

    while  norm(R(1:9))/r0 >= error_tol
        k = k +1;
        dfds = A*sigma_iter/M/M + a*(2*a'*sigma_iter - Pc_iter);

        R(1:9) = sigma_iter + Dlambda_iter*Ce*dfds - sigma_trial;
        R(10) = Pc_old*exp(Dlambda_iter/lambdap*I2'*dfds) - Pc_iter;
        R(11) = sigma_iter'*A*sigma_iter/2/M/M + a'*sigma_iter*(a'*sigma_iter - Pc_iter);

        % Jacobian
        
        temp = Pc_old*exp(Dlambda_iter/lambdap*I2'*dfds);
        J(1:9, 1:9) = I4 + Dlambda_iter*Ce*(A/M/M + 2*(a*a'));
        J(1:9, 10) = Ce*dfds;
        J(1:9, 11) = -Dlambda_iter*Ce*a;

        J(10, 1:9) = Dlambda_iter/lambdap*temp*I2'*(A/M/M + 2*(a*a'));
        J(10, 10) = temp/lambdap*I2'*dfds;
        J(10, 11) = -Dlambda_iter/lambdap*temp*I2'*a - 1;
        J(11, 1:9) = transpose(dfds);
        J(11, 11) = -a'*sigma_iter;

        solu_vari = J\R;
        % Update
        sigma_iter = sigma_iter - solu_vari(1:9);
        Dlambda_iter = Dlambda_iter - solu_vari(10);
        Pc_iter = Pc_iter - solu_vari(11);
        
        if k > 20
            break;
        end

    end
    
    sigma_new = sigma_iter;
    Pc_new = Pc_iter;
    hsv(1) = Pc_new;
    DSTRAIN_P = reshape(strain_incr, [9,1]) - Ce\(sigma_new - reshape(sigma_old, [9,1])); % plastic strain increment
    DSTRAIN_P = reshape(DSTRAIN_P, [3,3]);
    hsv(2) = hsv0(2) + sqrt(2/3)*norm(DSTRAIN_P, 'fro'); % Equivalent plastic strain based on norm of plastic strain tensor

    % Important: compute ACTO
    J11 = J(1:9,1:9);
    J12 = J(1:9,10);
    J13 = J(1:9,11);
    J21 = J(10,1:9);
    J22 = J(10,10);
    J23 = J(10,11);
    J31 = J(11,1:9);
    J33 = J(11,11);

    x = [(J21*(J11\J12) - J22)*I4, (J21*(J11\J13) - J23)*I4; ...
    (J31*(J11\J12))*I4, (J31*(J11\J13) - J33)*I4]\...
    [(J21*(J11\Ce))'; (J31*(J11\Ce))']; % x is 18*1

    ACTO = J11\Ce - (J11\J12)*x(1:9)' - (J11\J13)*x(10:end)'; % 9*9
    
    % for bifurcation analysis (material itself elastoplastic tangent) 9*9 matrix
    dfds = A*sigma_new/M/M + a*(2*a'*sigma_new - Pc_new);
    dfdpc = -a'*sigma_new;
    chi = dfds'*Ce*dfds - dfdpc*Pc_new/lambdap*trace(reshape(dfds,[3,3]));
    Cep = Ce - (Ce*dfds)*(dfds'*Ce)/chi;
end

sigma_new = reshape(sigma_new, [3,3]);
STRESS = [sigma_new(1,1); sigma_new(2,2); sigma_new(3,3); sigma_new(1,2); sigma_new(1,3); sigma_new(2,3)];

% E = zeros(9,3); E(1,1) = 1; E(5, 2) = 1; E(2, 3) = 0.5; E(4, 3) = 0.5;
% index = [1, 5, 4];
% DDSDDE = ACTO*E;
% DDSDDE = DDSDDE(index, :);
% 
% DELAS = Ce*E; % Elastic matrix for modified nodal integration of SFEM
% DELAS = DELAS(index, :);


E = zeros(9,6); E(1,1) = 1; E(5, 2) = 1; E(9, 3) = 1; E(2, 4) = 0.5; E(4, 4) = 0.5; E(3, 5) = 0.5; E(7, 5) = 0.5; E(6, 6) = 0.5; E(8, 6) = 0.5;
index1 = [1, 5, 9, 4, 7, 8];
index2 = [1, 5, 9, 2, 3, 6];
DDSDDE = ACTO*E;
DDSDDE = (DDSDDE(index1, :) + DDSDDE(index2, :))/2;  % 6*6 matrix

DELAS = Ce*E; % Elastic matrix for modified nodal integration of SFEM
DELAS = (DELAS(index1, :) + DELAS(index2, :))/2;  % 6*6 matrix









